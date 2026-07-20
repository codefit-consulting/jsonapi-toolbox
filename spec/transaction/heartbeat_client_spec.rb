# frozen_string_literal: true

require "spec_helper"
require "jsonapi_toolbox/client"
require "jsonapi_toolbox/transaction"

# Covers the client half of README §4.1: the automatic heartbeat thread and the
# cadence it derives from the granted lease, plus the request-serialiser that
# keeps it from racing real requests on the pinned socket.
RSpec.describe "Client automatic heartbeat" do
  after { JsonapiToolbox::Transaction.reset_configuration! }

  let(:transaction_class) do
    Class.new(JsonapiToolbox::Client::Transaction) do
      self.site = "https://example.com/api/"
      def self.resource_name
        "transaction"
      end
    end
  end

  # A stand-in for the json_api_client Transaction resource: only #id and
  # #attributes are read by the heartbeat machinery.
  def fake_txn(id: "txn-1", attributes: { lease_ttl: 30 })
    Class.new do
      define_method(:id) { id }
      define_method(:attributes) { attributes }
    end.new
  end

  # Records every request the heartbeat thread issues.
  let(:recorder) { [] }
  let(:recording_conn) do
    rec = recorder
    Class.new do
      define_method(:run) do |method, path, headers: {}, **_|
        rec << [method, path, headers]
      end
    end.new
  end

  describe ".heartbeat_interval" do
    it "is granted_ttl / divisor" do
      JsonapiToolbox::Transaction.configure { |c| c.heartbeat_divisor = 3; c.heartbeat_min_interval = 1 }
      interval = transaction_class.send(:heartbeat_interval, fake_txn(attributes: { lease_ttl: 30 }), JsonapiToolbox::Transaction.configuration)
      expect(interval).to eq(10.0)
    end

    it "is floored at heartbeat_min_interval" do
      JsonapiToolbox::Transaction.configure { |c| c.heartbeat_divisor = 3; c.heartbeat_min_interval = 5 }
      interval = transaction_class.send(:heartbeat_interval, fake_txn(attributes: { lease_ttl: 6 }), JsonapiToolbox::Transaction.configuration)
      expect(interval).to eq(5.0)
    end

    it "falls back to the configured lease_ttl_default when the response omits lease_ttl" do
      JsonapiToolbox::Transaction.configure { |c| c.heartbeat_divisor = 2; c.heartbeat_min_interval = 1; c.lease_ttl_default = 20 }
      interval = transaction_class.send(:heartbeat_interval, fake_txn(attributes: {}), JsonapiToolbox::Transaction.configuration)
      expect(interval).to eq(10.0)
    end
  end

  describe "start/stop" do
    it "POSTs /transactions/:id/heartbeat on the pinned connection and stops cleanly" do
      JsonapiToolbox::Transaction.configure do |c|
        c.heartbeat_divisor = 3
        c.heartbeat_min_interval = 0.02
      end
      pending = { txn: fake_txn(attributes: { lease_ttl: 0.15 }), connection: recording_conn }

      transaction_class.send(:start_heartbeat!, pending)
      thread = pending[:heartbeat_thread]
      expect(thread).to be_a(Thread)

      sleep(0.2)
      transaction_class.send(:stop_heartbeat!, pending)

      expect(thread).not_to be_alive
      expect(pending[:heartbeat_thread]).to be_nil
      expect(recorder).not_to be_empty
      method, path, headers = recorder.first
      expect(method).to eq(:post)
      expect(path).to eq("transactions/txn-1/heartbeat")
      expect(headers["X-Transaction-ID"]).to eq("txn-1")
    end

    it "stop_heartbeat! is a no-op when no heartbeat was started" do
      expect { transaction_class.send(:stop_heartbeat!, {}) }.not_to raise_error
    end
  end

  describe "socket safety" do
    around do |ex|
      JsonapiToolbox::Client.configure { |c| c.persistent_connections = false }
      ex.run
    ensure
      JsonapiToolbox::Client.reset_configuration!
    end

    it "installs the request serialiser on the dedicated (pinned) connection" do
      klass = Class.new(JsonapiToolbox::Client::Base) do
        self.site = "https://example.com/api/"
        def self.resource_name
          "widget"
        end
      end

      dedicated = klass.build_dedicated_connection
      handlers = dedicated.faraday.builder.handlers
      expect(handlers).to include(JsonapiToolbox::Client::RequestSerializerMiddleware)
    end
  end
end
