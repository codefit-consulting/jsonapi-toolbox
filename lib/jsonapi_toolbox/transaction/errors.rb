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
