# frozen_string_literal: true

require "spec_helper"
require "logger"
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

    it "quiesce_heartbeat! lets the thread exit at its next wake-up without another ping" do
      JsonapiToolbox::Transaction.configure { |c| c.heartbeat_divisor = 3; c.heartbeat_min_interval = 0.05 }
      pending = { txn: fake_txn(attributes: { lease_ttl: 0.15 }), connection: recording_conn }

      transaction_class.send(:start_heartbeat!, pending)
      transaction_class.send(:quiesce_heartbeat!, pending)
      thread = pending[:heartbeat_thread]
      thread.join(1)

      expect(thread).not_to be_alive
      expect(recorder).to be_empty
    end
  end

  # What the heartbeat thread does with each failure class. A bare 404 from
  # the receiver means "no such transaction" on the worker that answered —
  # i.e. the pinned socket was lost and the ping landed on a stranger. That
  # is not a lease expiry and must not be reported as one.
  describe "failure handling" do
    let(:events) { [] }
    let(:logger) { instance_double(Logger, warn: nil, info: nil, error: nil) }

    let(:subscriptions) do
      %w[transaction_affinity_lost heartbeat_failed].map do |name|
        ActiveSupport::Notifications.subscribe("#{name}.jsonapi_toolbox") do |*args|
          events << ActiveSupport::Notifications::Event.new(*args)
        end
      end
    end

    before do
      subscriptions
      JsonapiToolbox::Transaction.logger = logger
      JsonapiToolbox::Transaction.configure { |c| c.heartbeat_divisor = 3; c.heartbeat_min_interval = 0.02 }
    end

    after do
      subscriptions.each { |s| ActiveSupport::Notifications.unsubscribe(s) }
      JsonapiToolbox::Transaction.logger = nil
    end

    # A connection whose #run raises the given errors in order, then succeeds.
    def failing_conn(*errors)
      rec = recorder
      queue = errors.dup
      Class.new do
        define_method(:run) do |method, path, headers: {}, **_|
          rec << [method, path, headers]
          error = queue.shift
          raise error if error
        end
      end.new
    end

    def not_found(message = "Transaction not found: txn-1")
      JsonApiClient::Errors::NotFound.new(message)
    end

    # lease 0.06 / divisor 3 => 0.02 s cadence (the configured floor).
    def run_heartbeat(conn)
      pending = { txn: fake_txn(attributes: { lease_ttl: 0.06 }), connection: conn }
      transaction_class.send(:start_heartbeat!, pending)
      sleep(0.15)
      transaction_class.send(:stop_heartbeat!, pending)
      pending
    end

    it "stops and reports affinity lost on a bare NotFound" do
      run_heartbeat(failing_conn(not_found))

      expect(recorder.length).to eq(1)
      expect(events.map(&:name)).to eq(["transaction_affinity_lost.jsonapi_toolbox"])
      expect(events.first.payload[:transaction_id]).to eq("txn-1")
      expect(events.first.payload[:error]).to be_a(JsonApiClient::Errors::NotFound)
      expect(logger).to have_received(:warn).with(/txn=txn-1 .*affinity lost/)
    end

    it "stops silently on a typed TransactionReaped" do
      reaped = JsonapiToolbox::Client::TransactionReaped.new(
        { url: URI("https://example.com/api/transactions/txn-1/heartbeat") },
        transaction_id: "txn-1", reason: "lease_expired"
      )
      run_heartbeat(failing_conn(reaped))

      expect(recorder.length).to eq(1)
      expect(events).to be_empty
      expect(logger).not_to have_received(:warn)
    end

    it "does not report a NotFound on a ping that was already in flight when quiesced" do
      # The race: the ping wakes just before commit, blocks behind the commit
      # PATCH on the request serialiser, then goes out against a slot the
      # commit has just closed. Model the block with a gate inside #run.
      entered = Queue.new
      release = Queue.new
      gated_conn = Class.new do
        define_method(:run) do |*_, **_|
          entered << :in
          release.pop
          raise JsonApiClient::Errors::NotFound.new("Transaction not found: txn-1")
        end
      end.new

      pending = { txn: fake_txn(attributes: { lease_ttl: 0.06 }), connection: gated_conn }
      transaction_class.send(:start_heartbeat!, pending)
      entered.pop                                        # ping is inside #run
      transaction_class.send(:quiesce_heartbeat!, pending) # "commit" starts
      release << :go                                     # ping completes: 404
      pending[:heartbeat_thread].join(1)

      expect(pending[:heartbeat_thread]).not_to be_alive
      expect(events).to be_empty
      expect(logger).not_to have_received(:warn)
    end

    it "keeps pinging through transient errors and reports each one" do
      run_heartbeat(failing_conn(Faraday::ConnectionFailed.new("reset"), Timeout::Error.new("read")))

      expect(recorder.length).to be >= 3
      expect(events.map(&:name).uniq).to eq(["heartbeat_failed.jsonapi_toolbox"])
      expect(events.length).to eq(2)
      expect(logger).to have_received(:warn).with(/txn=txn-1 failed: Faraday::ConnectionFailed/)
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

      dedicated = klass.build_dedicated_connection(transaction_class: transaction_class, txn: nil)
      handlers = dedicated.faraday.builder.handlers
      expect(handlers).to include(JsonapiToolbox::Client::RequestSerializerMiddleware)
    end
  end
end
