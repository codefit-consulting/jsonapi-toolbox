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
      txn = manager.create(timeout_seconds: 10)
      expect(txn).to be_a(JsonapiToolbox::Transaction::HeldTransaction)
      expect(txn.state).to eq("open")
    end

    it "respects max_timeout configuration" do
      JsonapiToolbox::Transaction.configure { |c| c.max_timeout = 5 }
      txn = manager.create(timeout_seconds: 30)
      expect(txn.timeout_seconds).to eq(5)
    end

    it "uses default_timeout when none specified" do
      JsonapiToolbox::Transaction.configure { |c| c.default_timeout = 15 }
      txn = manager.create
      expect(txn.timeout_seconds).to eq(15)
    end

    it "raises ConcurrencyLimitError when limit reached" do
      JsonapiToolbox::Transaction.configure { |c| c.max_concurrent = 1 }
      manager.create(timeout_seconds: 10)

      expect {
        manager.create(timeout_seconds: 10)
      }.to raise_error(JsonapiToolbox::Transaction::Errors::ConcurrencyLimitError)
    end
  end

  describe "#find" do
    it "returns the transaction by ID" do
      txn = manager.create(timeout_seconds: 10)
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
      txn = manager.create(timeout_seconds: 10)
      manager.commit(txn.id)

      expect(txn.state).to eq("committed")
      expect {
        manager.find(txn.id)
      }.to raise_error(JsonapiToolbox::Transaction::Errors::NotFoundError)
    end
  end

  describe "#rollback" do
    it "rolls back and removes the transaction" do
      txn = manager.create(timeout_seconds: 10)
      manager.rollback(txn.id)

      expect(txn.state).to eq("rolled_back")
      expect {
        manager.find(txn.id)
      }.to raise_error(JsonapiToolbox::Transaction::Errors::NotFoundError)
    end
  end

  describe "#active_transactions" do
    it "returns only open transactions" do
      txn1 = manager.create(timeout_seconds: 10)
      txn2 = manager.create(timeout_seconds: 10)
      manager.commit(txn1.id)

      active = manager.active_transactions
      expect(active.map(&:id)).to eq([txn2.id])
    end
  end

  describe "#active_count" do
    it "returns the count of open transactions" do
      manager.create(timeout_seconds: 10)
      manager.create(timeout_seconds: 10)
      expect(manager.active_count).to eq(2)
    end
  end
end
