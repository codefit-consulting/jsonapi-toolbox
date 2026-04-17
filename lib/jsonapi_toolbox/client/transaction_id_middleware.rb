# frozen_string_literal: true

require "faraday"

module JsonapiToolbox
  module Client
    # Adds the X-Transaction-ID header to any request made while a remote
    # transaction is open on the current thread, and materialises a pending
    # transaction (created by Transaction.within_transaction) on the first
    # non-/transactions request.
    #
    # Wired into every connection built from JsonapiToolbox::Client::Base,
    # so all resource classes that inherit from it automatically participate
    # in remote transactions.
    class TransactionIdMiddleware < Faraday::Middleware
      HEADER = "X-Transaction-ID"

      def call(env)
        pending = Thread.current[Base::PENDING_TRANSACTION_KEY]

        if pending && pending[:txn].nil? && !transactions_endpoint?(env, pending)
          pending[:transaction_class].materialize_pending!(pending)
        end

        if (id = Thread.current[Base::TRANSACTION_ID_KEY]) &&
           env.request_headers[HEADER].nil?
          env.request_headers[HEADER] = id
        end

        @app.call(env)
      end

      private

      # Matches the transactions collection (POST /transactions) or a
      # single-member URL (PATCH/GET /transactions/<id>). Uses the
      # Transaction subclass's own table_name so apps that rename it
      # (rare) still work.
      def transactions_endpoint?(env, pending)
        base = pending[:transaction_class].table_name
        path = env.url.path
        path.end_with?("/#{base}") ||
          path.match?(%r{/#{Regexp.escape(base)}/[^/]+\z})
      end
    end
  end
end
