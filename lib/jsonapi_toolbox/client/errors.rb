# frozen_string_literal: true

require "json_api_client"

module JsonapiToolbox
  module Client
    module Errors
      # Raised (by TransactionReapedMiddleware) when a request comes back
      # referencing a held transaction the receiver has already reaped — the
      # caller went silent past its lease, or blew the hard_cap. Subclasses
      # json_api_client's NotFound so existing `rescue NotFound` paths still
      # treat "slot already gone" as before, while callers that want the clear,
      # self-describing signal rescue this type specifically and read the txn id
      # + reason instead of string-scraping a degraded "Resource not found: URL".
      class TransactionReaped < JsonApiClient::Errors::NotFound
        attr_reader :transaction_id, :reason

        def initialize(env, transaction_id: nil, reason: nil)
          @transaction_id = transaction_id
          @reason = reason
          message =
            if reason.to_s == "hard_cap_ttl_exceeded"
              "Remote transaction #{transaction_id} was reaped: it exceeded its " \
                "hard_cap_ttl (a runaway). The operation did not complete; nothing was saved."
            else
              "Remote transaction #{transaction_id} was reaped after the caller " \
                "stopped heartbeating (caller presumed dead). The operation did " \
                "not complete; nothing was saved."
            end
          super(env, message)
        end
      end
    end

    # Convenience constant so callers can `rescue JsonapiToolbox::Client::TransactionReaped`.
    TransactionReaped = Errors::TransactionReaped
  end
end
