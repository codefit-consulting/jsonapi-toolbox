# frozen_string_literal: true

require "securerandom"

module JsonapiToolbox
  module Transaction
    class HeldTransaction
      attr_reader :id, :state, :timeout_seconds, :expires_at, :created_at

      STATES = %w[open committed rolled_back].freeze

      def initialize(timeout_seconds:)
        @id = SecureRandom.uuid
        @timeout_seconds = timeout_seconds
        @state = "open"
        @created_at = Time.now
        @expires_at = @created_at + timeout_seconds
        @operation_queue = Queue.new
        @mutex = Mutex.new
        @thread = nil
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

      def expired?
        open? && Time.now > @expires_at
      end

      def alive?
        @thread&.alive? || false
      end

      def as_json
        {
          id: @id,
          state: @state,
          timeout_seconds: @timeout_seconds,
          expires_at: @expires_at.utc.iso8601,
          created_at: @created_at.utc.iso8601
        }
      end

      private

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
