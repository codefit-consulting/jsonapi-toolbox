# frozen_string_literal: true

require "spec_helper"
require "jsonapi_toolbox/client"
require "jsonapi_toolbox/transaction"
require "faraday/adapter/test"
require "active_support/notifications"

# When the block inside within_transaction raises, the rescue arm tries to
# rollback the held transaction. If that rollback itself fails, the server
# slot leaks until its timeout. This spec covers how those rollback
# failures are reported:
#
# - A 404 means the slot is already gone (reaped, foreign worker, etc.) —
#   the desired outcome — and should be silently treated as success.
# - Any other rollback failure should be logged via the configured logger
#   AND emit an `rollback_failed.jsonapi_toolbox` AS::Notifications event
#   so the leak is observable.
RSpec.describe "within_transaction rollback failure reporting" do
  around do |ex|
    original = Faraday.default_adapter
    Faraday.default_adapter = :test
    JsonapiToolbox::Client.configure { |c| c.persistent_connections = false }
    ex.run
  ensure
    Faraday.default_adapter = original
    JsonapiToolbox::Client.reset_configuration!
  end

  let(:rollback_response) { ->(_env) { [200, json_headers, patch_success_body("rolled_back")] } }

  let(:stubs) do
    s = Faraday::Adapter::Test::Stubs.new
    rb = rollback_response
    s.post("/api/transactions") do
      [200, json_headers, txn_body]
    end
    s.patch("/api/transactions/txn-1") do |env|
      body = JSON.parse(env.body)
      state = body.dig("data", "attributes", "state")
      if state == "rolled_back"
        rb.call(env)
      else
        [200, json_headers, patch_success_body("committed")]
      end
    end
    s.post("/api/widgets") do
      [200, json_headers, widget_body]
    end
    s
  end

  let(:transaction_class) do
    s = stubs
    Class.new(JsonapiToolbox::Client::Transaction) do
      self.site = "https://example.com/api/"
      def self.resource_name
        "transaction"
      end
      connection do |conn|
        conn.faraday.builder.adapter :test, s
      end
    end
  end

  let(:widget_class) do
    s = stubs
    Class.new(JsonapiToolbox::Client::Base) do
      self.site = "https://example.com/api/"
      def self.resource_name
        "widget"
      end
      connection do |conn|
        conn.faraday.builder.adapter :test, s
      end
    end
  end

  let(:txn_body) do
    { data: { type: "transactions", id: "txn-1",
              attributes: { state: "open", timeout_seconds: 30 } } }.to_json
  end

  let(:widget_body) do
    { data: { type: "widgets", id: "1", attributes: {} } }.to_json
  end

  def patch_success_body(state)
    { data: { type: "transactions", id: "txn-1",
              attributes: { state: state, timeout_seconds: 30 } } }.to_json
  end

  def json_headers
    { "Content-Type" => "application/vnd.api+json" }
  end

  def collect_events(name)
    events = []
    sub = ActiveSupport::Notifications.subscribe(name) do |*args|
      events << ActiveSupport::Notifications::Event.new(*args)
    end
    yield
    events
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end

  context "when the rollback PATCH returns 404 (slot already gone)" do
    let(:rollback_response) do
      ->(_env) { [404, json_headers, { errors: [{ status: "404", title: "Not Found" }] }.to_json] }
    end

    it "treats it as success — no warning, no notification event, caller's exception propagates" do
      logger = instance_double(Logger, warn: nil, info: nil, error: nil)
      JsonapiToolbox::Transaction.logger = logger

      events = collect_events("rollback_failed.jsonapi_toolbox") do
        expect do
          transaction_class.within_transaction do
            widget_class.create(name: "w")
            raise "boom"
          end
        end.to raise_error("boom")
      end

      expect(events).to be_empty
      expect(logger).not_to have_received(:warn).with(/rollback failed/)
    ensure
      JsonapiToolbox::Transaction.logger = nil
    end
  end

  context "when the rollback PATCH fails with a server error" do
    let(:rollback_response) do
      ->(_env) { [500, json_headers, { errors: [{ status: "500", title: "Boom" }] }.to_json] }
    end

    it "logs a warning and emits a rollback_failed notification, but still raises the caller's error" do
      logger = instance_double(Logger, warn: nil, info: nil, error: nil)
      JsonapiToolbox::Transaction.logger = logger

      events = collect_events("rollback_failed.jsonapi_toolbox") do
        expect do
          transaction_class.within_transaction do
            widget_class.create(name: "w")
            raise "boom"
          end
        end.to raise_error("boom")
      end

      expect(events.size).to eq(1)
      expect(events.first.payload[:transaction_id]).to eq("txn-1")
      expect(events.first.payload[:error]).to be_a(StandardError)

      expect(logger).to have_received(:warn).with(/rollback failed/)
      expect(logger).to have_received(:warn).with(/txn=txn-1/)
    ensure
      JsonapiToolbox::Transaction.logger = nil
    end
  end

  context "when rollback succeeds (default)" do
    it "emits no rollback_failed event and logs no warning" do
      logger = instance_double(Logger, warn: nil, info: nil, error: nil)
      JsonapiToolbox::Transaction.logger = logger

      events = collect_events("rollback_failed.jsonapi_toolbox") do
        expect do
          transaction_class.within_transaction do
            widget_class.create(name: "w")
            raise "boom"
          end
        end.to raise_error("boom")
      end

      expect(events).to be_empty
      expect(logger).not_to have_received(:warn).with(/rollback failed/)
    ensure
      JsonapiToolbox::Transaction.logger = nil
    end
  end
end
