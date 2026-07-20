# frozen_string_literal: true

require "faraday"

module JsonapiToolbox
  module Client
    # Response middleware that turns a receiver's "transaction reaped" signal
    # into a typed JsonapiToolbox::Client::TransactionReaped.
    #
    # json_api_client inserts middleware added via Connection#use *before*
    # Faraday::Response::Json and *after* its own Middleware::Status, so on the
    # response path this runs with the body already parsed to a Hash and BEFORE
    # Status would raise a generic NotFound. When meta.transaction_reaped is set
    # we raise the typed error here; otherwise we do nothing and Status handles
    # the response exactly as before.
    class TransactionReapedMiddleware < Faraday::Middleware
      def call(env)
        @app.call(env).on_complete do |response_env|
          detect_reaped!(response_env)
        end
      end

      private

      def detect_reaped!(env)
        body = env[:body]
        return unless body.is_a?(Hash)

        meta = body["meta"] || body[:meta]
        return unless meta.is_a?(Hash)

        reaped = meta["transaction_reaped"] || meta[:transaction_reaped]
        return unless reaped

        transaction_id = meta["transaction_id"] || meta[:transaction_id]
        reason = meta["reason"] || meta[:reason]

        raise JsonapiToolbox::Client::TransactionReaped.new(
          env, transaction_id: transaction_id, reason: reason
        )
      end
    end
  end
end
