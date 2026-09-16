# frozen_string_literal: true

require "spec_helper"
require "jsonapi_toolbox/client"
require "jsonapi_toolbox/transaction"
require "support/keepalive_server"

# The worker-affinity pin is a TCP socket. net-http-persistent's default
# idle_timeout (5 s) is shorter than the heartbeat interval, so after a quiet
# gap the client used to open a *new* socket — accepted by whichever receiver
# worker was free, i.e. one that had never seen the transaction. The dedicated
# connection must instead keep its one socket for `granted lease_ttl +
# pinned_socket_idle_grace`: long enough to outlive the slot itself.
RSpec.describe "transaction-pinned connection" do
  after do
    JsonapiToolbox::Client.reset_configuration!
    JsonapiToolbox::Transaction.reset_configuration!
  end

  let(:server) { KeepaliveServer.new }
  after { server.close }

  let(:resource_class) do
    site = server.site
    Class.new(JsonapiToolbox::Client::Base) do
      self.site = site
      def self.resource_name
        "widget"
      end
    end
  end

  let(:transaction_class) do
    site = server.site
    Class.new(JsonapiToolbox::Client::Transaction) do
      self.site = site
      def self.resource_name
        "transaction"
      end
    end
  end

  # Stand-in for the materialised json_api_client resource: only #attributes
  # (the receiver's echoed grant) is read.
  def granted(lease_ttl)
    Class.new do
      define_method(:attributes) { { lease_ttl: lease_ttl } }
    end.new
  end

  def pending(txn: nil, requested_lease_ttl: nil)
    { transaction_class: transaction_class, txn: txn, requested_lease_ttl: requested_lease_ttl }
  end

  # Two requests with an idle gap between them; returns sockets opened.
  def sockets_used(conn, gap:)
    before = server.accepts
    conn.run(:get, "widgets/1")
    sleep(gap)
    conn.run(:get, "widgets/1")
    server.accepts - before
  ensure
    conn.faraday.close if conn.faraday.respond_to?(:close)
  end

  describe ".pinned_socket_idle_timeout" do
    before { JsonapiToolbox::Transaction.configure { |c| c.pinned_socket_idle_grace = 30 } }

    it "is the granted lease plus grace once materialised" do
      expect(transaction_class.pinned_socket_idle_timeout(pending(txn: granted(45)))).to eq(75.0)
    end

    it "uses the lease this transaction will request before the grant arrives" do
      expect(transaction_class.pinned_socket_idle_timeout(pending(requested_lease_ttl: 10))).to eq(40.0)
    end

    it "falls back to the configured requested_lease_ttl, then lease_ttl_default" do
      JsonapiToolbox::Transaction.configure { |c| c.requested_lease_ttl = 20 }
      expect(transaction_class.pinned_socket_idle_timeout(pending)).to eq(50.0)

      JsonapiToolbox::Transaction.configure { |c| c.requested_lease_ttl = nil; c.lease_ttl_default = 60 }
      expect(transaction_class.pinned_socket_idle_timeout(pending)).to eq(90.0)
    end

    it "rejects a nil/zero grace (Net::HTTP would fall back to its own 2 s keep-alive)" do
      JsonapiToolbox::Transaction.configure { |c| c.pinned_socket_idle_grace = nil }
      expect { transaction_class.pinned_socket_idle_timeout(pending) }
        .to raise_error(ArgumentError, /pinned_socket_idle_grace/)

      JsonapiToolbox::Transaction.configure { |c| c.pinned_socket_idle_grace = 0 }
      expect { transaction_class.pinned_socket_idle_timeout(pending) }
        .to raise_error(ArgumentError, /pinned_socket_idle_grace/)
    end
  end

  describe "on the wire" do
    # Proves the computed value reaches the socket without a 5 s sleep:
    # shrink lease + grace below the gap and the client must re-open; with
    # a realistic lease it must not.
    it "re-opens the socket when the idle gap exceeds lease + grace" do
      JsonapiToolbox::Transaction.configure { |c| c.pinned_socket_idle_grace = 0.1 }
      conn = resource_class.build_dedicated_connection(pending(txn: granted(0.1)))
      # >= rather than == 2: net-http-persistent 3.x reconnects twice on an
      # expired connection; what matters is that it did not stay on one.
      expect(sockets_used(conn, gap: 0.5)).to be >= 2
    end

    it "keeps one socket across an idle gap within lease + grace" do
      conn = resource_class.build_dedicated_connection(pending(txn: granted(30)))
      expect(sockets_used(conn, gap: 0.5)).to eq(1)
    end

    it "tracks the lease as it is granted mid-connection" do
      JsonapiToolbox::Transaction.configure { |c| c.pinned_socket_idle_grace = 0.1 }
      marker = pending(requested_lease_ttl: 0.1)
      conn = resource_class.build_dedicated_connection(marker)

      conn.run(:get, "widgets/1")
      marker[:txn] = granted(30) # the receiver's grant arrives
      before = server.accepts
      conn.run(:get, "widgets/1") # config block re-reads: timeout is now 30.1
      sleep(0.5)
      conn.run(:get, "widgets/1")
      expect(server.accepts - before).to eq(0)
    ensure
      conn.faraday.close if conn && conn.faraday.respond_to?(:close)
    end
  end

  describe "adapter reconfiguration" do
    def adapter_handler(conn)
      JsonapiToolbox::Client::FaradayBuilder.adapter_handler(conn.faraday.builder)
    end

    it "keeps the net_http_persistent adapter, with a single-socket pool and a config block" do
      handler = adapter_handler(resource_class.build_dedicated_connection(pending))

      expect(handler.klass.name).to include("NetHttpPersistent")
      adapter = handler.build(nil)
      expect(adapter.instance_variable_get(:@connection_options)).to include(pool_size: 1)
      expect(adapter.instance_variable_get(:@config_block)).to respond_to(:call)
    end

    it "leaves exactly one adapter on the stack" do
      handlers = resource_class.build_dedicated_connection(pending).faraday.builder.handlers
      expect(handlers.count { |h| h.klass <= Faraday::Adapter }).to be <= 1
    end

    it "does not touch the shared (load-balanced) connection" do
      adapter = adapter_handler(resource_class.connection).build(nil)
      expect(adapter.instance_variable_get(:@connection_options)).not_to include(:pool_size)
      expect(adapter.instance_variable_get(:@config_block)).to be_nil
    end

    it "is skipped when persistent connections are disabled" do
      JsonapiToolbox::Client.configure { |c| c.persistent_connections = false }
      fresh = Class.new(JsonapiToolbox::Client::Base) { self.site = "https://example.com/api/" }
      handler = adapter_handler(fresh.build_dedicated_connection(pending))
      expect(handler.klass.name).not_to include("NetHttpPersistent")
    end
  end
end
