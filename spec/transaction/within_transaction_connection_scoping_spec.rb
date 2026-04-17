# frozen_string_literal: true

require "spec_helper"
require "jsonapi_toolbox/client"
require "jsonapi_toolbox/transaction"
require "faraday/adapter/test"

# Covers the multi-worker affinity fix: inside within_transaction, every
# Client::Base subclass must route requests through a single shared Faraday
# connection, so keep-alive pins all traffic to one server worker. Outside
# the block, each subclass keeps using its own connection (load balancing
# preserved).
RSpec.describe "within_transaction connection scoping" do
  around do |ex|
    original = Faraday.default_adapter
    Faraday.default_adapter = :test
    JsonapiToolbox::Client.configure { |c| c.persistent_connections = false }
    ex.run
  ensure
    Faraday.default_adapter = original
    JsonapiToolbox::Client.reset_configuration!
  end

  let(:stubs) { Faraday::Adapter::Test::Stubs.new }

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

  let(:gadget_class) do
    s = stubs
    Class.new(JsonapiToolbox::Client::Base) do
      self.site = "https://example.com/api/"
      def self.resource_name
        "gadget"
      end
      connection do |conn|
        conn.faraday.builder.adapter :test, s
      end
    end
  end

  def json_response(body)
    [200, { "Content-Type" => "application/vnd.api+json" }, body]
  end

  let(:txn_body) do
    { data: { type: "transactions", id: "txn-1",
              attributes: { state: "open", timeout_seconds: 30 } } }.to_json
  end

  let(:committed_body) do
    { data: { type: "transactions", id: "txn-1",
              attributes: { state: "committed", timeout_seconds: 30 } } }.to_json
  end

  before do
    stubs.post("/api/transactions") { json_response(txn_body) }
    stubs.patch("/api/transactions/txn-1") { json_response(committed_body) }
    stubs.post("/api/widgets") do
      json_response({ data: { type: "widgets", id: "1", attributes: {} } }.to_json)
    end
    stubs.post("/api/gadgets") do
      json_response({ data: { type: "gadgets", id: "1", attributes: {} } }.to_json)
    end
  end

  describe "inside the block" do
    it "routes every Client::Base subclass through the same Faraday connection" do
      captured = []
      transaction_class
      widget_class
      gadget_class

      transaction_class.within_transaction do
        captured << transaction_class.connection.object_id
        captured << widget_class.connection.object_id
        captured << gadget_class.connection.object_id

        widget_class.create(name: "w")
        gadget_class.create(name: "g")
      end

      expect(captured.uniq.length).to eq(1)
    end

    it "uses a connection distinct from each class's own connection_object" do
      outer_widget_conn = widget_class.connection
      outer_txn_conn = transaction_class.connection

      inside_conn = nil
      transaction_class.within_transaction do
        inside_conn = widget_class.connection
      end

      expect(inside_conn).not_to equal(outer_widget_conn)
      expect(inside_conn).not_to equal(outer_txn_conn)
    end
  end

  describe "outside the block" do
    it "leaves each subclass using its own connection_object" do
      w1 = widget_class.connection
      g1 = gadget_class.connection

      transaction_class.within_transaction { widget_class.create(name: "w") }

      expect(widget_class.connection).to equal(w1)
      expect(gadget_class.connection).to equal(g1)
      expect(w1).not_to equal(g1)
    end
  end

  describe "cleanup" do
    it "clears the thread-local after the block completes" do
      transaction_class.within_transaction { widget_class.create(name: "w") }
      expect(Thread.current[JsonapiToolbox::Client::Base::PENDING_TRANSACTION_KEY]).to be_nil
    end

    it "clears the thread-local when the block raises" do
      expect do
        stubs.patch("/api/transactions/txn-1") do
          json_response(
            { data: { type: "transactions", id: "txn-1",
                      attributes: { state: "rolled_back", timeout_seconds: 30 } } }.to_json
          )
        end
        transaction_class.within_transaction { raise "boom" }
      end.to raise_error("boom")

      expect(Thread.current[JsonapiToolbox::Client::Base::PENDING_TRANSACTION_KEY]).to be_nil
    end

    it "closes the dedicated connection on exit" do
      captured_conn = nil
      allow(transaction_class).to receive(:build_dedicated_connection).and_wrap_original do |orig|
        captured_conn = orig.call
      end

      transaction_class.within_transaction { widget_class.create(name: "w") }

      expect(captured_conn).not_to be_nil
      # Faraday::Connection#close is idempotent; calling again shouldn't raise.
      expect { captured_conn.faraday.close }.not_to raise_error
    end
  end

  describe "concurrent transactions" do
    it "gives each thread its own dedicated connection" do
      seen = Queue.new
      gate_in = Queue.new
      gate_out = Queue.new

      threads = 2.times.map do
        Thread.new do
          transaction_class.within_transaction do
            seen << widget_class.connection.object_id
            gate_in << :reached
            gate_out.pop # hold the block open until both threads reported
          end
        end
      end

      2.times { gate_in.pop }
      ids = []
      ids << seen.pop
      ids << seen.pop
      2.times { gate_out << :go }
      threads.each(&:join)

      expect(ids.uniq.length).to eq(2)
    end
  end

  describe "reentrancy" do
    it "reuses the outer dedicated connection for nested within_transaction calls" do
      inner_conn = nil
      outer_conn = nil
      transaction_class.within_transaction do
        outer_conn = widget_class.connection
        transaction_class.within_transaction do
          inner_conn = widget_class.connection
        end
      end

      expect(inner_conn).to equal(outer_conn)
    end
  end

  describe "header propagation under the dedicated connection" do
    # The default stub for /api/widgets above is one-shot per test; register
    # a second matching stub so our request inside the block matches this one
    # and we can capture its headers.
    it "still attaches X-Transaction-ID to sibling resource requests" do
      captured_headers = []
      stubs.post("/api/widgets") do |env|
        captured_headers << env.request_headers.dup
        json_response({ data: { type: "widgets", id: "1", attributes: {} } }.to_json)
      end

      # Consume the default stub registered in the outer `before` so our
      # capturing stub is next in line for this path.
      widget_class.create(name: "priming")

      transaction_class.within_transaction do
        widget_class.create(name: "w")
      end

      expect(captured_headers.length).to eq(1)
      expect(captured_headers.first["X-Transaction-ID"]).to eq("txn-1")
    end
  end
end
