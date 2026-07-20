# frozen_string_literal: true

require "securerandom"

module JsonapiToolbox
  module Transaction
    class HeldTransaction
      # lease_ttl: the granted lease (reap if idle this long). hard_cap_ttl: the
      # absolute lifetime ceiling regardless of heartbeats (nil disables it).
      attr_reader :id, :state, :lease_ttl, :hard_cap_ttl, :created_at, :op_count

      STATES = %w[open committed rolled_back].freeze

      def initialize(lease_ttl:, hard_cap_ttl: nil)
        @id = SecureRandom.uuid
        @lease_ttl = lease_ttl
        @hard_cap_ttl = hard_cap_ttl
        @state = "open"
        @op_count = 0

        # Wall-clock stamp for display/serialization only.
        @created_at = Time.now
        # Monotonic stamps drive every reap decision, so an NTP step can't cause
        # a false reap. last_seen advances on any heartbeat OR real op.
        @created_mono = monotonic_now
        @last_seen_mono = @created_mono

        @operation_queue = Queue.new
        @mutex = Mutex.new
        @thread = nil
      end

      # Display-only expiry: a rough "reap by if idle from now" wall-clock hint.
      # Not used for reaping (that's monotonic + sliding on last_seen).
      def expires_at
        @created_at + @lease_ttl
      end

      def start!
        @thread = Thread.new { run_transaction_loop }
        # Wait for the transaction thread to signal it has started and acquired
        # a connection. The thread pushes :ready onto the operation queue's
        # result channel once BEGIN has executed.
        ready_queue = Queue.new
        @operation_queue.push([:ready_check, ready_queue])
        ready_queue.pop
        self
      end

      def execute(&block)
        raise Errors::ExpiredError.new(id) unless open?

        result_queue = Queue.new
        @operation_queue.push([:execute, result_queue, block])
        status, value = result_queue.pop

        raise value if status == :error

        value
      end

      def commit!
        transition_to!("committed")
      end

      def rollback!
        transition_to!("rolled_back")
      end

      def open?
        @mutex.synchronize { @state == "open" }
      end

      # Records liveness. Called on any inbound message carrying this txn's id —
      # a heartbeat OR a real op. A real op also bumps op_count. Mutex-guarded so
      # the reaper thread reads a consistent last_seen.
      def touch!(counts_as_op: false)
        @mutex.synchronize do
          @last_seen_mono = monotonic_now
          @op_count += 1 if counts_as_op
        end
      end

      # Seconds since the last heartbeat/op (the reaper's liveness signal).
      def idle_for
        monotonic_now - @mutex.synchronize { @last_seen_mono }
      end

      # Seconds since creation (drives the hard_cap runaway check).
      def age
        monotonic_now - @created_mono
      end

      # The caller went silent for longer than its lease → presumed dead.
      def lease_expired?
        idle_for > @lease_ttl
      end

      # Alive and still heartbeating, but past the absolute sanity ceiling.
      # nil hard_cap_ttl disables this branch entirely.
      def hard_cap_ttl_exceeded?
        !@hard_cap_ttl.nil? && age > @hard_cap_ttl
      end

      # nil when the txn should live; otherwise the reason to reap it.
      def reap_reason
        return :lease_expired if lease_expired?
        return :hard_cap_ttl_exceeded if hard_cap_ttl_exceeded?
        nil
      end

      def expired?
        open? && !reap_reason.nil?
      end

      def alive?
        @thread&.alive? || false
      end

      def as_json
        {
          id: @id,
          state: @state,
          lease_ttl: @lease_ttl,
          hard_cap_ttl: @hard_cap_ttl,
          op_count: @op_count,
          expires_at: expires_at.utc.iso8601,
          created_at: @created_at.utc.iso8601
        }
      end

      private

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def transition_to!(new_state)
        @mutex.synchronize do
          raise Errors::ExpiredError.new(id) if @state != "open"
          @state = new_state
        end
        result_queue = Queue.new
        @operation_queue.push([:terminate, result_queue, new_state])
        result_queue.pop
      end

      # Runs on the dedicated transaction thread. Checks out an AR connection
      # and holds a PG transaction open for the lifetime of this held
      # transaction. Operations from request threads are received via the
      # operation queue and executed inside SAVEPOINTs.
      def run_transaction_loop
        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.transaction do
            loop do
              instruction, result_queue, payload = @operation_queue.pop

              case instruction
              when :ready_check
                result_queue.push(:ready)

              when :execute
                begin
                  value = ActiveRecord::Base.transaction(requires_new: true) { payload.call }
                  result_queue.push([:success, value])
                rescue => e
                  result_queue.push([:error, Errors::OperationError.new(e, transaction_rolled_back: false)])
                end

              when :terminate
                if payload == "committed"
                  # Let the transaction block exit normally to COMMIT
                  result_queue.push(:done)
                  break
                else
                  # Raise to trigger ROLLBACK
                  result_queue.push(:done)
                  raise ActiveRecord::Rollback
                end
              end
            end
          end
        end
      rescue => e
        # If the transaction thread dies unexpectedly, mark as rolled back
        @mutex.synchronize { @state = "rolled_back" }
        JsonapiToolbox::Transaction.logger&.error(
          "[Transaction #{@id}] Thread died unexpectedly: #{e.class} - #{e.message}"
        )
      end
    end
  end
end
