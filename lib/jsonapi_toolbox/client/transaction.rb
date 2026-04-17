# frozen_string_literal: true

module JsonapiToolbox
  module Client
    # JSON:API resource for managing held transactions on a remote app.
    # Follows the same pattern as every other resource in the system —
    # apps subclass and set `site` + service token:
    #
    #   # In v2, pointed at v1:
    #   class V1::Transaction < JsonapiToolbox::Client::Transaction
    #     self.site = "https://v1.example.com/api/internal/"
    #     configure_service_token -> { ServiceToken.current }
    #   end
    #
    #   # Then use it like any other resource:
    #   txn = V1::Transaction.create(timeout_seconds: 30)
    #   txn.commit!
    #   txn.rollback!
    #   txn.state          # => "open" / "committed" / "rolled_back"
    #   V1::Transaction.find(id)
    #   V1::Transaction.all
    #
    # Commit and rollback are standard PATCH updates on the `state` attribute.
    #
    class Transaction < Base
      def commit!
        update_attributes(state: "committed")
        raise_if_errors!
        self
      end

      def rollback!
        update_attributes(state: "rolled_back")
        raise_if_errors!
        self
      end

      def open?
        state == "open"
      end

      # Convenience: create a transaction, then commit (or rollback on error).
      # While the block runs, every request from a JsonapiToolbox::Client::Base
      # subclass on this thread carries the X-Transaction-ID header, courtesy
      # of TransactionIdMiddleware on the shared connection stack.
      #
      #   V1::Transaction.within_transaction(timeout_seconds: 30) do
      #     V1::Hotel.create!(name: "Test")
      #     V1::RoomType.create!(hotel_id: 1, name: "Suite")
      #   end
      #
      def self.within_transaction(timeout_seconds: nil)
        # Re-entrant: if we're already inside a remote transaction on this
        # thread, just yield into the existing one (no extra round trip).
        if Thread.current[:jsonapi_toolbox_transaction_id]
          return yield
        end

        txn = create(timeout_seconds: timeout_seconds)
        raise_on_create_errors!(txn)

        begin
          Thread.current[:jsonapi_toolbox_transaction_id] = txn.id
          result = yield txn
          txn.commit!
          result
        rescue StandardError
          txn.rollback! rescue nil
          raise
        ensure
          Thread.current[:jsonapi_toolbox_transaction_id] = nil
        end
      end

      private

      def raise_if_errors!
        return if errors.blank?

        raise JsonapiToolbox::Transaction::Errors::TransactionError,
          errors.full_messages.join(", ")
      end

      def self.raise_on_create_errors!(txn)
        return if txn.errors.blank?

        message = txn.errors.full_messages.join(", ")

        if txn.errors.any? { |e| e.status == "429" rescue false }
          raise JsonapiToolbox::Transaction::Errors::ConcurrencyLimitError.new(0)
        end

        raise JsonapiToolbox::Transaction::Errors::TransactionError, message
      end

      private_class_method :raise_on_create_errors!
    end
  end
end
