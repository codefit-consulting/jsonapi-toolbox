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

      # Create a transaction, run the block, commit (or rollback on error).
      #
      # Creation is **lazy**: no remote request is issued at block entry.
      # Instead, a thread-local pending marker is set, and
      # TransactionIdMiddleware materialises the transaction — POST
      # /transactions on the same dedicated connection that will carry the
      # rest of the block's traffic — on the first non-/transactions
      # request inside the block. Blocks that make no remote requests
      # cost nothing on the wire: no POST, no PATCH, no held-transaction
      # slot consumed on the server.
      #
      #   V1::Transaction.within_transaction(timeout_seconds: 30) do |txn|
      #     V1::Hotel.create!(name: "Test")
      #     V1::RoomType.create!(hotel_id: 1, name: "Suite")
      #   end
      #
      # The yielded `txn` is a LazyTransaction proxy. If the block makes
      # no remote calls, `txn.state` reads "not_opened" and `txn.id` is
      # nil. Otherwise it forwards to the underlying transaction resource.
      def self.within_transaction(timeout_seconds: nil)
        # Reentrant: if an outer within_transaction on this thread has
        # already set a pending marker (materialised or not), just yield
        # into it. The outer owns creation, commit, and rollback.
        if (existing = Thread.current[Base::PENDING_TRANSACTION_KEY])
          return yield(LazyTransaction.new(existing))
        end

        pending = {
          transaction_class: self,
          timeout_seconds: timeout_seconds,
          connection: nil,
          txn: nil
        }
        Thread.current[Base::PENDING_TRANSACTION_KEY] = pending

        begin
          result = yield(LazyTransaction.new(pending))
          pending[:txn]&.commit!
          result
        rescue StandardError
          begin
            pending[:txn]&.rollback!
          rescue StandardError
            # Best-effort rollback; don't mask the caller's real error.
          end
          raise
        ensure
          Thread.current[Base::TRANSACTION_ID_KEY] = nil
          Thread.current[Base::PENDING_TRANSACTION_KEY] = nil
          close_dedicated_connection(pending[:connection])
        end
      end

      # Called from TransactionIdMiddleware on the first non-/transactions
      # request inside a within_transaction block. Issues POST
      # /transactions, stores the result on the pending marker, and sets
      # the thread-local id so the middleware's header-attach picks it up
      # for this request and every subsequent one.
      def self.materialize_pending!(pending)
        txn = create(timeout_seconds: pending[:timeout_seconds])
        raise_on_create_errors!(txn)
        pending[:txn] = txn
        Thread.current[Base::TRANSACTION_ID_KEY] = txn.id
        txn
      end

      # Best-effort shutdown of the transaction-scoped connection's socket
      # pool. Swallows errors so a bad close never masks the caller's real
      # result (or exception).
      def self.close_dedicated_connection(conn)
        return unless conn
        conn.faraday.close if conn.faraday.respond_to?(:close)
      rescue StandardError
        nil
      end
      private_class_method :close_dedicated_connection

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
