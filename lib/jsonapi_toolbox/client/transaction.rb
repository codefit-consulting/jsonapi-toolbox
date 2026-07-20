# frozen_string_literal: true

require "active_support/notifications"

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
    #   txn = V1::Transaction.create(requested_lease_ttl: 30)
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
      #   V1::Transaction.within_transaction do |txn|
      #     V1::Hotel.create!(name: "Test")
      #     V1::RoomType.create!(hotel_id: 1, name: "Suite")
      #   end
      #
      # Optionally request a lease and/or a hard_cap_ttl for *this* transaction
      # (each clamped by the receiver's policy). The common one is a tighter
      # hard_cap_ttl than the receiver's generous default, sized to the work:
      #
      #   # this touches a handful of records — cap it at 2 min, not the ~1h default
      #   V1::Transaction.within_transaction(requested_hard_cap_ttl: 120) do
      #     V1::Hotel.create!(name: "Test")
      #   end
      #
      # Per-transaction requests fall back to the configured
      # `requested_lease_ttl` / `requested_hard_cap_ttl`, then the server default.
      #
      # The yielded `txn` is a LazyTransaction proxy. If the block makes
      # no remote calls, `txn.state` reads "not_opened" and `txn.id` is
      # nil. Otherwise it forwards to the underlying transaction resource.
      def self.within_transaction(requested_lease_ttl: nil, requested_hard_cap_ttl: nil)
        # Reentrant: if an outer within_transaction on this thread has
        # already set a pending marker (materialised or not), just yield
        # into it. The outer owns creation, commit, and rollback (so any
        # lease/hard_cap requested on an inner call is ignored — the outer's win).
        if (existing = Thread.current[Base::PENDING_TRANSACTION_KEY])
          return yield(LazyTransaction.new(existing))
        end

        pending = {
          transaction_class: self,
          requested_lease_ttl: requested_lease_ttl,
          requested_hard_cap_ttl: requested_hard_cap_ttl,
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
          rescue JsonApiClient::Errors::NotFound
            # Slot is already gone server-side (reaped, foreign worker,
            # already committed/rolled back). That's the outcome rollback
            # was trying to achieve — treat as success.
          rescue StandardError => rollback_error
            report_rollback_failure(pending[:txn], rollback_error)
          end
          raise
        ensure
          # Stop the heartbeat first so it can't fire against a slot we're
          # tearing down, then clear markers and close the pinned connection.
          stop_heartbeat!(pending)
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
        txn = create(create_attributes(pending))
        raise_on_create_errors!(txn)
        pending[:txn] = txn
        Thread.current[Base::TRANSACTION_ID_KEY] = txn.id
        start_heartbeat!(pending)
        txn
      end

      # Build the POST /transactions attributes: the lease/hard_cap_ttl this
      # transaction requests. Per-transaction values (from within_transaction)
      # win, then the app-configured defaults; anything still nil is omitted so
      # the receiver applies its own default. All requests are clamped by the
      # receiver's policy.
      def self.create_attributes(pending)
        config = JsonapiToolbox::Transaction.configuration

        lease = pending[:requested_lease_ttl]
        lease = config.requested_lease_ttl if lease.nil?

        hard_cap_ttl = pending[:requested_hard_cap_ttl]
        hard_cap_ttl = config.requested_hard_cap_ttl if hard_cap_ttl.nil?

        attrs = {}
        attrs[:requested_lease_ttl] = lease unless lease.nil?
        attrs[:requested_hard_cap_ttl] = hard_cap_ttl unless hard_cap_ttl.nil?
        attrs
      end
      private_class_method :create_attributes

      # Start the automatic heartbeat: a background thread that POSTs
      # /transactions/:id/heartbeat every granted_ttl/divisor seconds (floored
      # at heartbeat_min_interval), proving the caller process is alive so the
      # receiver reaps only a genuinely dead caller. Bound to the transaction
      # lifecycle — no caller code touches it. Runs on the same worker-pinned
      # connection (serialised with real requests by RequestSerializerMiddleware).
      def self.start_heartbeat!(pending)
        txn = pending[:txn]
        conn = pending[:connection]
        return unless txn && conn

        config = JsonapiToolbox::Transaction.configuration
        interval = heartbeat_interval(txn, config)
        id = txn.id
        path = "#{table_name}/#{id}/heartbeat"

        thread = Thread.new do
          loop do
            sleep(interval)
            begin
              conn.run(:post, path, headers: { TransactionIdMiddleware::HEADER => id })
            rescue JsonApiClient::Errors::NotFound
              break # slot gone (reaped / committed) — stop pinging
            rescue StandardError
              # transient failure — keep trying; the reaper covers a dead caller
            end
          end
        end
        thread.abort_on_exception = false
        thread.name = "jsonapi-toolbox-txn-heartbeat"
        pending[:heartbeat_thread] = thread
      end
      private_class_method :start_heartbeat!

      def self.stop_heartbeat!(pending)
        thread = pending[:heartbeat_thread]
        return unless thread
        thread.kill
        thread.join(1)
      rescue StandardError
        nil
      ensure
        pending[:heartbeat_thread] = nil
      end
      private_class_method :stop_heartbeat!

      # Cadence = max(granted_ttl / divisor, min_interval), reading the granted
      # lease the receiver echoed in the create response (falling back to the
      # client's own configured default if the response omitted it).
      def self.heartbeat_interval(txn, config)
        attrs = txn.respond_to?(:attributes) ? txn.attributes : {}
        granted = attrs[:lease_ttl] || attrs["lease_ttl"] || config.lease_ttl_default
        divisor = config.heartbeat_divisor.to_f
        divisor = 1.0 if divisor <= 0
        [granted.to_f / divisor, config.heartbeat_min_interval.to_f].max
      end
      private_class_method :heartbeat_interval

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

      # Surface rollback failures that aren't "slot already gone" — they
      # indicate a server-side slot that will sit held until its timeout.
      # Logs via the configured Transaction.logger and emits an
      # `rollback_failed.jsonapi_toolbox` AS::Notifications event so apps
      # can wire up alerting. Never re-raises: the caller's original
      # exception is what matters and is about to be re-raised by the
      # within_transaction rescue arm.
      def self.report_rollback_failure(txn, error)
        txn_id = txn&.id

        JsonapiToolbox::Transaction.logger&.warn(
          "[JsonapiToolbox::Transaction] within_transaction rollback failed " \
          "for txn=#{txn_id || '(unknown)'}: #{error.class}: #{error.message}. " \
          "Server-side slot will leak until timeout."
        )

        ActiveSupport::Notifications.instrument(
          "rollback_failed.jsonapi_toolbox",
          transaction_id: txn_id,
          error: error
        )
      rescue StandardError
        nil
      end
      private_class_method :report_rollback_failure

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
