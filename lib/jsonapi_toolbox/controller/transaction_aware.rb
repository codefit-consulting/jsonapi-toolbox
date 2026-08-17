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

      # request.env slot carrying transaction-state metadata for the in-flight
      # request. Written before an operation error is handed off to the app's
      # rescue_from chain; read by render helpers (and available to app-level
      # handlers) so error responses can surface transaction state.
      TRANSACTION_META_ENV_KEY = "jsonapi_toolbox.transaction"

      # Transaction-state metadata for the in-flight request, or nil when the
      # request isn't executing against a held transaction or no operation error
      # occurred. Public so app-level rescue_from handlers can merge it into
      # their own responses (the gem's render_jsonapi_error does this for free).
      def transaction_error_meta
        request.env[TRANSACTION_META_ENV_KEY]
      end

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
      rescue JsonapiToolbox::Transaction::Errors::ReapedError => e
        # A reaped slot: render title (so the client's title-only harvester
        # picks it up) + meta.transaction_reaped so the client raises a typed
        # TransactionReaped instead of a misleading generic NotFound.
        render_transaction_error(
          "404", e.message,
          status: :not_found, transaction_id: txn_id, reaped: true, reason: e.reason
        )
        nil
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
        # The caller's block failed on the held transaction's thread and arrives
        # here wrapped as an OperationError. Previously we rendered it directly,
        # which silently overrode the host app's entire error-handling policy for
        # every in-transaction request. Instead: stash transaction-state metadata
        # on request.env, then hand the *original* error to the app's rescue_from
        # chain exactly as ActionController::Rescue#process_action does
        # (`rescue_with_handler(exception) || raise`). rescue_with_handler is
        # truthy when a handler matched (Rails 4.2 returns true, 5+ returns the
        # exception), nil otherwise — so an unhandled error falls back to the
        # gem's structured renderer, keeping a jsonapi error body (+ transaction
        # meta) for in-transaction requests instead of leaking a dev error page.
        request.env[TRANSACTION_META_ENV_KEY] = {
          transaction_id: txn_id,
          transaction_rolled_back: e.transaction_rolled_back
        }
        rescue_with_handler(e.original_error) || render_operation_error(e, txn_id)
        nil
      end

      def execute_on_held_transaction(txn_id, &block)
        manager = JsonapiToolbox::Transaction::Manager.instance
        txn = manager.find(txn_id)
        # A real op is itself proof of life: refresh last_seen and count it.
        txn.touch!(counts_as_op: true)

        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          result = txn.execute(&block)
        ensure
          emit_operation_event(txn, txn_id, started)
        end
        result
      end

      def emit_operation_event(txn, txn_id, started)
        duration = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        ActiveSupport::Notifications.instrument(
          "transaction_operation.jsonapi_toolbox",
          transaction_id: txn_id,
          endpoint: (request.path if respond_to?(:request)),
          verb: (request.request_method if respond_to?(:request)),
          in_txn: true,
          op_count: txn.op_count,
          duration: duration
        )
      rescue StandardError
        nil
      end

      def render_transaction_error(status_code, detail, status:, transaction_id: nil, rolled_back: nil, reaped: false, reason: nil)
        error = { status: status_code, title: detail, detail: detail }
        body = { errors: [error] }
        if reaped
          body[:meta] = {
            transaction_id: transaction_id,
            transaction_reaped: true,
            reason: reason
          }
        elsif transaction_id
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
          # title mirrors detail so json_api_client's title-only harvester
          # (errors.rb: map { |e| e['title'] }) surfaces a real message rather
          # than falling back to a generic one — matching render_transaction_error.
          errors: [{ status: status_code, title: detail, detail: detail }],
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
