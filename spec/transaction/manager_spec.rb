# frozen_string_literal: true

require "spec_helper"
require "jsonapi_toolbox/transaction"
require "support/test_database"

RSpec.describe JsonapiToolbox::Transaction::Manager do
  before(:all) do
    TestDatabase.setup!(pool: 15)
  end

  after(:all) do
    TestDatabase.teardown!
  end

  let(:manager) { described_class.instance }

  before do
    JsonapiToolbox::Transaction.reset_configuration!
  end

  after do
    manager.reset!
  end

  describe "#create" do
    it "creates a new held transaction" do
      txn = manager.create(requested_lease_ttl: 10)
      expect(txn).to be_a(JsonapiToolbox::Transaction::HeldTransaction)
      expect(txn.state).to eq("open")
    end

    it "clamps a requested lease to lease_ttl_max" do
      JsonapiToolbox::Transaction.configure { |c| c.lease_ttl_max = 50 }
      txn = manager.create(requested_lease_ttl: 300)
      expect(txn.lease_ttl).to eq(50)
    end

    it "clamps a requested lease up to lease_ttl_min" do
      JsonapiToolbox::Transaction.configure { |c| c.lease_ttl_min = 20 }
      txn = manager.create(requested_lease_ttl: 5)
      expect(txn.lease_ttl).to eq(20)
    end

    it "uses lease_ttl_default when none specified" do
      JsonapiToolbox::Transaction.configure { |c| c.lease_ttl_default = 15 }
      txn = manager.create
      expect(txn.lease_ttl).to eq(15)
    end

    it "honours a requested hard_cap_ttl up to hard_cap_ttl_max (no silent 60s clamp)" do
      JsonapiToolbox::Transaction.configure { |c| c.hard_cap_ttl_max = 3600 }
      txn = manager.create(requested_hard_cap_ttl: 300)
      expect(txn.hard_cap_ttl).to eq(300)
    end

    it "clamps a requested hard_cap_ttl to hard_cap_ttl_max" do
      JsonapiToolbox::Transaction.configure { |c| c.hard_cap_ttl_max = 200 }
      txn = manager.create(requested_hard_cap_ttl: 5000)
      expect(txn.hard_cap_ttl).to eq(200)
    end

    it "raises ConcurrencyLimitError when limit reached" do
      JsonapiToolbox::Transaction.configure { |c| c.max_concurrent = 1 }
      manager.create(requested_lease_ttl: 10)

      expect {
        manager.create(requested_lease_ttl: 10)
      }.to raise_error(JsonapiToolbox::Transaction::Errors::ConcurrencyLimitError)
    end
  end

  describe "#find" do
    it "returns the transaction by ID" do
      txn = manager.create(requested_lease_ttl: 10)
      found = manager.find(txn.id)
      expect(found.id).to eq(txn.id)
    end

    it "raises NotFoundError for unknown ID" do
      expect {
        manager.find("nonexistent")
      }.to raise_error(JsonapiToolbox::Transaction::Errors::NotFoundError)
    end
  end

  describe "#commit" do
    it "commits and removes the transaction" do
      txn = manager.create(requested_lease_ttl: 10)
      manager.commit(txn.id)

      expect(txn.state).to eq("committed")
      expect {
        manager.find(txn.id)
      }.to raise_error(JsonapiToolbox::Transaction::Errors::NotFoundError)
    end
  end

  describe "#rollback" do
    it "rolls back and removes the transaction" do
      txn = manager.create(requested_lease_ttl: 10)
      manager.rollback(txn.id)

      expect(txn.state).to eq("rolled_back")
      expect {
        manager.find(txn.id)
      }.to raise_error(JsonapiToolbox::Transaction::Errors::NotFoundError)
    end
  end

  describe "#active_transactions" do
    it "returns only open transactions" do
      txn1 = manager.create(requested_lease_ttl: 10)
      txn2 = manager.create(requested_lease_ttl: 10)
      manager.commit(txn1.id)

      active = manager.active_transactions
      expect(active.map(&:id)).to eq([txn2.id])
    end
  end

  describe "#active_count" do
    it "returns the count of open transactions" do
      manager.create(requested_lease_ttl: 10)
      manager.create(requested_lease_ttl: 10)
      expect(manager.active_count).to eq(2)
    end
  end

  describe "reap-on-pressure inside #create" do
    before do
      JsonapiToolbox::Transaction.configure do |c|
        c.max_concurrent = 1
        c.reaper_scan_interval = 100 # keep the background reaper out of the test
      end
    end

    it "sweeps expired transactions when at capacity, allowing the new create to succeed" do
      expired = manager.create(requested_lease_ttl: 10)
      # Simulate a caller that went silent past its lease: rewind last_seen.
      expired.instance_variable_set(:@last_seen_mono, expired.instance_variable_get(:@last_seen_mono) - 1000)
      expect(expired.expired?).to be true

      new_txn = nil
      expect { new_txn = manager.create(requested_lease_ttl: 10) }.not_to raise_error
      expect(new_txn.id).not_to eq(expired.id)
    end

    it "still raises ConcurrencyLimitError when nothing is reapable" do
      manager.create(requested_lease_ttl: 10)
      expect {
        manager.create(requested_lease_ttl: 10)
      }.to raise_error(JsonapiToolbox::Transaction::Errors::ConcurrencyLimitError)
    end
  end

  describe "reaper fork-awareness" do
    it "restarts the reaper when the recorded PID doesn't match Process.pid" do
      manager.create(requested_lease_ttl: 10)
      original_thread = manager.instance_variable_get(:@reaper_thread)
      expect(original_thread).to be_alive

      # Simulate a fork: the recorded PID is the parent's, the thread is gone.
      manager.instance_variable_set(:@reaper_pid, Process.pid + 999_999)
      original_thread.kill
      original_thread.join

      manager.create(requested_lease_ttl: 10)

      new_thread = manager.instance_variable_get(:@reaper_thread)
      expect(new_thread).not_to equal(original_thread)
      expect(new_thread).to be_alive
      expect(manager.instance_variable_get(:@reaper_pid)).to eq(Process.pid)
    end

    it "restarts the reaper when the thread has died" do
      manager.create(requested_lease_ttl: 10)
      original_thread = manager.instance_variable_get(:@reaper_thread)
      original_thread.kill
      original_thread.join
      expect(original_thread).not_to be_alive

      manager.create(requested_lease_ttl: 10)

      new_thread = manager.instance_variable_get(:@reaper_thread)
      expect(new_thread).not_to equal(original_thread)
      expect(new_thread).to be_alive
    end

    it "does not restart the reaper when it is already running in this process" do
      manager.create(requested_lease_ttl: 10)
      original_thread = manager.instance_variable_get(:@reaper_thread)

      manager.create(requested_lease_ttl: 10)

      expect(manager.instance_variable_get(:@reaper_thread)).to equal(original_thread)
    end
  end
end
