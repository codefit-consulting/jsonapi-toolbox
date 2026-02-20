# frozen_string_literal: true

module JsonapiToolbox
  module Controller
    # Server-side concern that detects the X-Transaction-ID header and
    # executes DB work on the held transaction's thread when present.
    #
    # Usage in a controller:
    #
    #   include JsonapiToolbox::Controller::TransactionAware
    #
    #   def create
    #     hotel = with_transaction_context do
    #       Hotel.create!(attributes)
    #     end
    #     render_jsonapi(hotel, status: :created)
    #   end
    #
    # When X-Transaction-ID is absent, the block executes normally on the
    # request thread. When present, the block is shipped to the held
    # transaction's thread and executed inside a SAVEPOINT.
    module TransactionAware
      extend ActiveSupport::Concern

      TRANSACTION_HEADER = "X-Transaction-ID"

      private

      def transaction_id_from_request
        request.headers[TRANSACTION_HEADER]
      end

      # Wraps a block of DB work. If a held transaction ID is present in the
      # request headers, the block executes on that transaction's thread.
      # Otherwise it executes inline.
      #
      # Returns the block's return value, or nil if an error was rendered.
      def with_transaction_context(&block)
        txn_id = transaction_id_from_request

        if txn_id
          execute_on_held_transaction(txn_id, &block)
        else
          yield
        end
      rescue JsonapiToolbox::Transaction::Errors::NotFoundError
        render_transaction_error("404", "Transaction not found: #{txn_id}", status: :not_found)
        nil
      rescue JsonapiToolbox::Transaction::Errors::ExpiredError
        render_transaction_error(
          "410", "Transaction expired: #{txn_id}",
          status: :gone, transaction_id: txn_id, rolled_back: true
        )
        nil
      rescue JsonapiToolbox::Transaction::Errors::OperationError => e
        render_operation_error(e, txn_id)
        nil
      end

      def execute_on_held_transaction(txn_id, &block)
        manager = JsonapiToolbox::Transaction::Manager.instance
        txn = manager.find(txn_id)
        txn.execute(&block)
      end

      def render_transaction_error(status_code, detail, status:, transaction_id: nil, rolled_back: nil)
        body = {
          errors: [{ status: status_code, detail: detail }]
        }
        if transaction_id
          body[:meta] = {
            transaction_id: transaction_id,
            transaction_rolled_back: rolled_back
          }
        end
        render json: body, status: status
      end

      def render_operation_error(error, txn_id)
        original = error.original_error

        detail = original.respond_to?(:record) && original.record ?
          original.record.errors.full_messages.join(", ") :
          original.message

        status_code = original.is_a?(ActiveRecord::RecordInvalid) ? "422" : "500"
        http_status = original.is_a?(ActiveRecord::RecordInvalid) ? :unprocessable_entity : :internal_server_error

        body = {
          errors: [{ status: status_code, detail: detail }],
          meta: {
            transaction_id: txn_id,
            transaction_rolled_back: error.transaction_rolled_back
          }
        }
        render json: body, status: http_status
      end
    end
  end
end
