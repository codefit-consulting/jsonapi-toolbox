# frozen_string_literal: true

module JsonapiToolbox
  module Transaction
    module Errors
      class TransactionError < StandardError; end

      class NotFoundError < TransactionError
        attr_reader :transaction_id

        def initialize(transaction_id)
          @transaction_id = transaction_id
          super("Transaction not found: #{transaction_id}")
        end
      end

      class ExpiredError < TransactionError
        attr_reader :transaction_id

        def initialize(transaction_id)
          @transaction_id = transaction_id
          super("Transaction expired: #{transaction_id}")
        end
      end

      # Raised when a request references a transaction the reaper has already
      # torn down (the caller went silent, or blew the hard_cap_ttl). Distinct
      # from NotFoundError — which means "never existed here" — so the controller
      # can render a legible, self-describing reap signal instead of a misleading
      # generic 404. `reason` is :lease_expired or :hard_cap_ttl_exceeded.
      class ReapedError < TransactionError
        attr_reader :transaction_id, :reason

        def initialize(transaction_id, reason: nil)
          @transaction_id = transaction_id
          @reason = reason
          detail = reason == :hard_cap_ttl_exceeded ?
            "Transaction #{transaction_id} was reaped: exceeded its hard_cap_ttl (runaway)" :
            "Transaction #{transaction_id} was reaped after the caller stopped heartbeating (caller presumed dead)"
          super(detail)
        end
      end

      class ConcurrencyLimitError < TransactionError
        attr_reader :limit

        def initialize(limit)
          @limit = limit
          super("Concurrency limit reached: maximum #{limit} held transactions per process")
        end
      end

      class OperationError < TransactionError
        attr_reader :original_error, :transaction_rolled_back

        def initialize(original_error, transaction_rolled_back: false)
          @original_error = original_error
          @transaction_rolled_back = transaction_rolled_back
          super(original_error.message)
        end
      end
    end
  end
end
