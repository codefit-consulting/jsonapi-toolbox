# frozen_string_literal: true

require "faraday"

module JsonapiToolbox
  module Client
    # Adds the X-Transaction-ID header to any request made while a remote
    # transaction is open on the current thread.
    #
    # Wired into every connection built from JsonapiToolbox::Client::Base,
    # so all resource classes that inherit from it automatically participate
    # in remote transactions opened by Transaction.within_transaction.
    class TransactionIdMiddleware < Faraday::Middleware
      HEADER = "X-Transaction-ID"

      def call(env)
        if (txn_id = Thread.current[:jsonapi_toolbox_transaction_id]) &&
           env.request_headers[HEADER].nil?
          env.request_headers[HEADER] = txn_id
        end
        @app.call(env)
      end
    end
  end
end
