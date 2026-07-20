# frozen_string_literal: true

require "active_support/notifications"

module JsonapiToolbox
  module Transaction
    class Manager
      include Singleton

      # How many reaped-transaction tombstones to retain so a follow-up request
      # can be told "reaped" (not "never existed"). Bounded FIFO — old entries
      # are only useful until the client notices, so a small cap is plenty.
      MAX_TOMBSTONES = 1024

      def initialize
        @transactions = {}
        @tombstones = {}       # id => { reason:, idle_for:, age:, op_count: }
        @tombstone_order = []  # FIFO of ids for eviction
        @mutex = Mutex.new
        @reaper_thread = nil
        @reaper_pid = nil
      end

      # Negotiated create. The client may propose a lease TTL and/or a
      # hard_cap_ttl; the receiver clamps both to its own policy, stores the
      # granted values on the held transaction, and (via the serializer) echoes
      # them back so the client can set its heartbeat cadence.
      def create(requested_lease_ttl: nil, requested_hard_cap_ttl: nil)
        ensure_reaper_alive!

        config = JsonapiToolbox::Transaction.configuration
        lease_ttl = clamp_lease_ttl(requested_lease_ttl, config)
        hard_cap_ttl = clamp_hard_cap_ttl(requested_hard_cap_ttl, config)

        if at_capacity?(config.max_concurrent)
          reap_expired
          if at_capacity?(config.max_concurrent)
            raise Errors::ConcurrencyLimitError.new(config.max_concurrent)
          end
        end

        txn = HeldTransaction.new(lease_ttl: lease_ttl, hard_cap_ttl: hard_cap_ttl)
        txn.start!

        @mutex.synchronize { @transactions[txn.id] = txn }

        log(:info, "Created transaction #{txn.id} (lease: #{lease_ttl}s, hard_cap_ttl: #{hard_cap_ttl.inspect})")
        instrument("transaction_materialized", id: txn.id, lease_ttl: lease_ttl, hard_cap_ttl: hard_cap_ttl)
        txn
      end

      def find(id)
        txn = @mutex.synchronize { @transactions[id] }
        return txn if txn

        tombstone = @mutex.synchronize { @tombstones[id] }
        raise Errors::ReapedError.new(id, reason: tombstone[:reason]) if tombstone

        raise Errors::NotFoundError.new(id)
      end

      # Records liveness for a transaction from an inbound heartbeat or real op.
      # Raises ReapedError/NotFoundError (via #find) if the slot is already gone.
      def heartbeat(id, counts_as_op: false)
        txn = find(id)
        txn.touch!(counts_as_op: counts_as_op)
        txn
      end

      def commit(id)
        txn = find(id)
        raise Errors::ExpiredError.new(id) unless txn.open?

        txn.commit!
        remove(id)
        log(:info, "Committed transaction #{id}")
        instrument("transaction_committed", id: id, op_count: txn.op_count, duration: txn.age)
        txn
      end

      def rollback(id)
        txn = find(id)
        raise Errors::ExpiredError.new(id) unless txn.open?

        txn.rollback!
        remove(id)
        log(:info, "Rolled back transaction #{id}")
        instrument("transaction_rolled_back", id: id, op_count: txn.op_count, duration: txn.age)
        txn
      end

      def active_transactions
        @mutex.synchronize { @transactions.values.select(&:open?) }
      end

      def active_count
        @mutex.synchronize { @transactions.count { |_, t| t.open? } }
      end

      def start_reaper!
        ensure_reaper_alive!
      end

      def stop_reaper!
        @reaper_thread&.kill
        @reaper_thread = nil
        @reaper_pid = nil
      end

      # Verifies the reaper thread is alive in *this* process. Ruby threads
      # do not survive fork(2), so a reaper started in a Puma master before
      # `preload_app!` will appear non-nil in workers but actually be dead.
      # Called from #create so consuming apps that forget to restart the
      # reaper in `on_worker_boot` still get a working pool.
      def ensure_reaper_alive!
        return if reaper_running?

        @mutex.synchronize do
          return if reaper_running?
          spawn_reaper_thread!
        end
      end

      def shutdown!
        stop_reaper!
        @mutex.synchronize do
          @transactions.each_value do |txn|
            txn.rollback! if txn.open?
          rescue => e
            log(:warn, "Error rolling back #{txn.id} during shutdown: #{e.message}")
          end
          @transactions.clear
        end
        log(:info, "Manager shut down")
      end

      def reset!
        shutdown!
        @transactions = {}
        @tombstones = {}
        @tombstone_order = []
      end

      private

      def clamp_lease_ttl(requested, config)
        return config.lease_ttl_default if requested.nil?
        [[requested, config.lease_ttl_min].max, config.lease_ttl_max].min
      end

      def clamp_hard_cap_ttl(requested, config)
        return config.hard_cap_ttl_default if requested.nil?
        return requested if config.hard_cap_ttl_max.nil?
        [requested, config.hard_cap_ttl_max].min
      end

      def reaper_running?
        @reaper_pid == Process.pid && @reaper_thread&.alive?
      end

      def spawn_reaper_thread!
        interval = JsonapiToolbox::Transaction.configuration.reaper_scan_interval

        @reaper_thread = Thread.new do
          loop do
            sleep(interval)
            reap_expired
          end
        end
        @reaper_thread.abort_on_exception = false
        @reaper_thread.name = "jsonapi-toolbox-txn-reaper"
        @reaper_pid = Process.pid
        log(:info, "Reaper started (pid: #{@reaper_pid}, interval: #{interval}s)")
      end

      def at_capacity?(max_concurrent)
        @mutex.synchronize { @transactions.size >= max_concurrent }
      end

      def remove(id)
        @mutex.synchronize { @transactions.delete(id) }
      end

      def reap_expired
        candidates = @mutex.synchronize { @transactions.values.select(&:open?) }
        candidates.each do |txn|
          reason = txn.reap_reason
          next unless reason

          idle_for = txn.idle_for
          age = txn.age
          op_count = txn.op_count

          log(:warn, "Reaping transaction #{txn.id} (reason: #{reason}, idle_for: #{idle_for.round(1)}s, op_count: #{op_count})")
          instrument(
            "transaction_reaped",
            id: txn.id, reason: reason, idle_for: idle_for, age: age, op_count: op_count
          )
          record_tombstone(txn.id, reason: reason, idle_for: idle_for, age: age, op_count: op_count)
          txn.rollback!
          remove(txn.id)
        rescue => e
          log(:warn, "Error reaping transaction #{txn.id}: #{e.message}")
          remove(txn.id)
        end
      end

      def record_tombstone(id, info)
        @mutex.synchronize do
          @tombstones[id] = info
          @tombstone_order << id
          if @tombstone_order.size > MAX_TOMBSTONES
            evicted = @tombstone_order.shift
            @tombstones.delete(evicted)
          end
        end
      end

      def instrument(event, payload)
        ActiveSupport::Notifications.instrument("#{event}.jsonapi_toolbox", payload)
      rescue StandardError
        nil
      end

      def log(level, message)
        JsonapiToolbox::Transaction.logger&.send(level, "[JsonapiToolbox::Transaction] #{message}")
      end
    end
  end
end
