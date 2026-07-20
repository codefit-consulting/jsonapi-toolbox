# frozen_string_literal: true

require "faraday"

module JsonapiToolbox
  module Client
    # Serialises every request made through a single Faraday connection behind a
    # per-connection mutex. Installed only on the dedicated connection that
    # Transaction.within_transaction pins to one server worker.
    #
    # Why: inside a within_transaction block the automatic heartbeat thread and
    # the main thread both issue requests on that one connection (and, under
    # net_http_persistent, one TCP socket). Concurrent use of a single socket
    # corrupts the HTTP stream. within_transaction is inherently serial on the
    # main thread, so this mutex adds negligible contention — it just prevents
    # the heartbeat from overlapping a real request.
    class RequestSerializerMiddleware < Faraday::Middleware
      def initialize(app, options = {})
        super(app)
        @mutex = options[:mutex] || Mutex.new
      end

      def call(env)
        @mutex.synchronize { @app.call(env) }
      end
    end
  end
end
