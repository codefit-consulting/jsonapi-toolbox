# frozen_string_literal: true

module JsonapiToolbox
  module Client
    # Proxy yielded from Transaction.within_transaction. Stands in for the
    # remote transaction resource while it may or may not have been
    # materialised — materialisation happens on the first non-/transactions
    # request made inside the block (see TransactionIdMiddleware).
    #
    # Inspection methods return useful defaults when no real transaction
    # has been created; mutating methods no-op. Callers that never touch
    # the yielded proxy (the common case) don't care either way.
    class LazyTransaction
      NOT_OPENED_STATE = "not_opened"

      def initialize(pending)
        @pending = pending
      end

      def id
        real&.id
      end

      def state
        real&.state || NOT_OPENED_STATE
      end

      def open?
        real ? real.open? : false
      end

      def materialized?
        !real.nil?
      end

      def commit!
        real&.commit!
        self
      end

      def rollback!
        real&.rollback!
        self
      end

      private

      def real
        @pending[:txn]
      end
    end
  end
end
