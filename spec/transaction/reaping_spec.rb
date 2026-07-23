# frozen_string_literal: true

require "spec_helper"
require "jsonapi_toolbox/transaction"
require "support/test_database"

# Covers the crash-only lease + heartbeat model (README §4) and the legible
# reaped signal (README §3, receiver half): the reaper reaps only a caller that
# has gone silent past its lease or blown the hard_cap, records a tombstone so a
# follow-up request is told "reaped" (not "never existed"), and emits an event.
RSpec.describe "Crash-only reaping" do
  before(:all) { TestDatabase.setup!(pool: 15) }
  after(:all) { TestDatabase.teardown! }

  let(:manager) { JsonapiToolbox::Transaction::Manager.instance }

  before { JsonapiToolbox::Transaction.reset_configuration! }
  after { manager.reset! }

  def rewind_last_seen(txn, seconds)
    now = txn.instance_variable_get(:@last_seen_mono)
    txn.instance_variable_set(:@last_seen_mono, now - seconds)
  end

  def rewind_created(txn, seconds)
    now = txn.instance_variable_get(:@created_mono)
    txn.instance_variable_set(:@created_mono, now - seconds)
  end

  describe JsonapiToolbox::Transaction::HeldTransaction do
    it "is not reapable while fresh" do
      txn = described_class.new(lease_ttl: 30)
      expect(txn.reap_reason).to be_nil
    end

    it "reaps as lease_expired once idle beyond the lease" do
      txn = described_class.new(lease_ttl: 10)
      rewind_last_seen(txn, 15)
      expect(txn.lease_expired?).to be true
      expect(txn.reap_reason).to eq(:lease_expired)
    end

    it "a heartbeat (touch!) refreshes liveness and prevents a reap" do
      txn = described_class.new(lease_ttl: 10)
      rewind_last_seen(txn, 15)
      expect(txn.reap_reason).to eq(:lease_expired)
      txn.touch!
      expect(txn.reap_reason).to be_nil
    end

    it "reaps as hard_cap_ttl_exceeded when alive but past the ceiling" do
      txn = described_class.new(lease_ttl: 30, hard_cap_ttl: 60)
      rewind_created(txn, 120)   # old
      # last_seen stays fresh → not lease-expired, only hard_cap trips
      expect(txn.lease_expired?).to be false
      expect(txn.hard_cap_ttl_exceeded?).to be true
      expect(txn.reap_reason).to eq(:hard_cap_ttl_exceeded)
    end

    it "never hard-caps when hard_cap is nil (disabled)" do
      txn = described_class.new(lease_ttl: 30, hard_cap_ttl: nil)
      rewind_created(txn, 100_000)
      expect(txn.hard_cap_ttl_exceeded?).to be false
      expect(txn.reap_reason).to be_nil
    end

    it "counts a real op as activity and bumps op_count" do
      txn = described_class.new(lease_ttl: 10)
      expect { txn.touch!(counts_as_op: true) }.to change(txn, :op_count).by(1)
    end
  end

  describe "Manager reap → tombstone → ReapedError" do
    it "reaps an idle transaction and then reports it as reaped, not missing" do
      txn = manager.create(requested_lease_ttl: 10)
      rewind_last_seen(txn, 1000)

      manager.send(:reap_expired)

      expect {
        manager.find(txn.id)
      }.to raise_error(JsonapiToolbox::Transaction::Errors::ReapedError) do |e|
        expect(e.transaction_id).to eq(txn.id)
        expect(e.reason).to eq(:lease_expired)
        expect(e.message).to include(txn.id)
      end
    end

    it "still raises NotFoundError for an id that never existed" do
      expect {
        manager.find("never-existed")
      }.to raise_error(JsonapiToolbox::Transaction::Errors::NotFoundError)
    end

    it "surfaces hard_cap_ttl_exceeded as the reap reason" do
      txn = manager.create(requested_lease_ttl: 30, requested_hard_cap_ttl: 60)
      rewind_created(txn, 120)

      manager.send(:reap_expired)

      expect { manager.find(txn.id) }
        .to raise_error(JsonapiToolbox::Transaction::Errors::ReapedError) { |e|
          expect(e.reason).to eq(:hard_cap_ttl_exceeded)
        }
    end

    it "heartbeat refreshes an at-risk transaction so the reaper spares it" do
      txn = manager.create(requested_lease_ttl: 10)
      rewind_last_seen(txn, 9) # close but not past
      manager.heartbeat(txn.id)
      manager.send(:reap_expired)
      expect(manager.find(txn.id).id).to eq(txn.id)
    end
  end

  # An op that runs longer than the lease must not get its own transaction
  # reaped mid-flight: the caller is alive and blocked waiting on it. An
  # in-flight op is proof of liveness (the lease is shielded), but the
  # hard_cap backstop stays unconditional so a genuinely stuck op is still
  # caught. A latch keeps the op deterministically in-flight while we inspect.
  describe "does not reap a held transaction that is actively executing an op" do
    # Drives one real op on the held thread, held in-flight by `release`.
    # Yields once the op is executing so the caller can inspect/reap, then
    # joins after release. Returns the op's result.
    def with_op_in_flight(txn)
      started = Queue.new
      release = Queue.new
      result = nil
      op_thread = Thread.new do
        result = txn.execute do
          started.push(:go)
          release.pop
          :op_result
        end
      end
      started.pop # the op is now executing on the held thread
      yield
      release.push(:go)
      op_thread.join
      result
    end

    it "spares an op that outlives its lease, and the op completes normally" do
      txn = manager.create(requested_lease_ttl: 10)
      manager.stop_reaper! # drive reaping deterministically

      result = with_op_in_flight(txn) do
        # The op has been running longer than the whole lease.
        rewind_last_seen(txn, 1000)

        expect(txn.busy?).to be true
        expect(txn.lease_expired?).to be false # busy shields the lease
        expect(txn.reap_reason).to be_nil

        manager.send(:reap_expired)
        expect { manager.find(txn.id) }.not_to raise_error
      end

      expect(result).to eq(:op_result)
      expect(txn.busy?).to be false
      # Completing the op refreshes last_seen, so it's not instantly reapable.
      expect(txn.reap_reason).to be_nil
    end

    it "still reaps a transaction that is idle with no op running (lease_expired)" do
      txn = manager.create(requested_lease_ttl: 10)
      manager.stop_reaper!
      rewind_last_seen(txn, 1000)

      expect(txn.busy?).to be false
      expect(txn.reap_reason).to eq(:lease_expired)

      manager.send(:reap_expired)
      expect { manager.find(txn.id) }
        .to raise_error(JsonapiToolbox::Transaction::Errors::ReapedError) { |e|
          expect(e.reason).to eq(:lease_expired)
        }
    end

    it "still reaps an op that blows the hard_cap (runaway backstop, busy notwithstanding)" do
      txn = manager.create(requested_lease_ttl: 10, requested_hard_cap_ttl: 60)
      manager.stop_reaper!

      with_op_in_flight(txn) do
        rewind_created(txn, 120) # past the hard cap while the op is in-flight

        expect(txn.busy?).to be true
        expect(txn.hard_cap_ttl_exceeded?).to be true
        # busy shields the lease but NOT the hard cap.
        expect(txn.reap_reason).to eq(:hard_cap_ttl_exceeded)
      end
    end
  end

  describe "instrumentation" do
    it "emits transaction_reaped with reason, idle_for, age and op_count" do
      events = []
      subscription = ActiveSupport::Notifications.subscribe("transaction_reaped.jsonapi_toolbox") do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end

      txn = manager.create(requested_lease_ttl: 10)
      rewind_last_seen(txn, 1000)
      manager.send(:reap_expired)

      expect(events.size).to eq(1)
      payload = events.first.payload
      expect(payload[:id]).to eq(txn.id)
      expect(payload[:reason]).to eq(:lease_expired)
      expect(payload).to include(:idle_for, :age, :op_count)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end

    it "emits transaction_materialized on create" do
      events = []
      subscription = ActiveSupport::Notifications.subscribe("transaction_materialized.jsonapi_toolbox") do |*args|
        events << ActiveSupport::Notifications::Event.new(*args)
      end

      txn = manager.create(requested_lease_ttl: 25)
      expect(events.map { |e| e.payload[:id] }).to include(txn.id)
      expect(events.last.payload[:lease_ttl]).to eq(25)
    ensure
      ActiveSupport::Notifications.unsubscribe(subscription)
    end
  end
end
