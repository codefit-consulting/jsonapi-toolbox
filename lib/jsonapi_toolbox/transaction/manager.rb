# frozen_string_literal: true

module JsonapiToolbox
  module Transaction
    class Manager
      include Singleton

      def initialize
        @transactions = {}
        @mutex = Mutex.new
        @reaper_thread = nil
        @reaper_pid = nil
      end

      def create(timeout_seconds: nil)
        ensure_reaper_alive!

        config = JsonapiToolbox::Transaction.configuration
        timeout = [timeout_seconds || config.default_timeout, config.max_timeout].min

        if at_capacity?(config.max_concurrent)
          reap_expired
          if at_capacity?(config.max_concurrent)
            raise Errors::ConcurrencyLimitError.new(config.max_concurrent)
          end
        end

        txn = HeldTransaction.new(timeout_seconds: timeout)
        txn.start!

        @mutex.synchronize { @transactions[txn.id] = txn }

        log(:info, "Created transaction #{txn.id} (timeout: #{timeout}s)")
        txn
      end

      def find(id)
        @mutex.synchronize { @transactions[id] } || raise(Errors::NotFoundError.new(id))
      end

      def commit(id)
        txn = find(id)
        raise Errors::ExpiredError.new(id) unless txn.open?

        txn.commit!
        remove(id)
        log(:info, "Committed transaction #{id}")
        txn
      end

      def rollback(id)
        txn = find(id)
        raise Errors::ExpiredError.new(id) unless txn.open?

        txn.rollback!
        remove(id)
        log(:info, "Rolled back transaction #{id}")
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
      end

      private

      def reaper_running?
        @reaper_pid == Process.pid && @reaper_thread&.alive?
      end

      def spawn_reaper_thread!
        interval = JsonapiToolbox::Transaction.configuration.reaper_interval

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
        expired = @mutex.synchronize { @transactions.values.select(&:expired?) }
        expired.each do |txn|
          log(:warn, "Reaping expired transaction #{txn.id}")
          txn.rollback!
          remove(txn.id)
        rescue => e
          log(:warn, "Error reaping transaction #{txn.id}: #{e.message}")
          remove(txn.id)
        end
      end

      def log(level, message)
        JsonapiToolbox::Transaction.logger&.send(level, "[JsonapiToolbox::Transaction] #{message}")
      end
    end
  end
end
