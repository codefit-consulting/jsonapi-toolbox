# frozen_string_literal: true

require "spec_helper"
require "jsonapi_toolbox/transaction"
require "support/test_database"

RSpec.describe JsonapiToolbox::Transaction::HeldTransaction do
  before(:all) do
    TestDatabase.setup!

    ActiveRecord::Schema.define do
      create_table :test_records, force: true do |t|
        t.string :name, null: false
      end
    end

    class TestRecord < ActiveRecord::Base
      validates :name, presence: true
    end
  end

  after(:all) do
    ActiveRecord::Base.connection.drop_table(:test_records, if_exists: true)
    Object.send(:remove_const, :TestRecord)
    TestDatabase.teardown!
  end

  # Clean test_records between examples
  after do
    TestRecord.delete_all
  rescue
    nil
  end

  let(:txn) { described_class.new(timeout_seconds: 10) }

  describe "#initialize" do
    it "generates a UUID id" do
      expect(txn.id).to match(/\A[0-9a-f-]{36}\z/)
    end

    it "starts in the open state" do
      expect(txn.state).to eq("open")
    end

    it "calculates expires_at from timeout" do
      expect(txn.expires_at).to be > txn.created_at
    end
  end

  describe "#start! and #execute" do
    after { txn.rollback! if txn.open? }

    it "executes a block on the transaction thread and returns the result" do
      txn.start!
      result = txn.execute { 1 + 1 }
      expect(result).to eq(2)
    end

    it "executes AR operations on the held connection" do
      txn.start!
      record = txn.execute { TestRecord.create!(name: "test") }
      expect(record).to be_a(TestRecord)
      expect(record.name).to eq("test")
    end

    it "wraps operations in SAVEPOINTs so failures don't kill the transaction" do
      txn.start!

      # This should fail (validation error) but not kill the outer transaction
      expect {
        txn.execute { TestRecord.create!(name: nil) }
      }.to raise_error(JsonapiToolbox::Transaction::Errors::OperationError)

      # Transaction should still be alive
      expect(txn.open?).to be true

      # Subsequent operations should work
      record = txn.execute { TestRecord.create!(name: "after_failure") }
      expect(record.name).to eq("after_failure")
    end
  end

  describe "#commit!" do
    it "transitions state to committed" do
      txn.start!
      txn.commit!
      expect(txn.state).to eq("committed")
    end
  end

  describe "#rollback!" do
    it "transitions state to rolled_back" do
      txn.start!
      txn.rollback!
      expect(txn.state).to eq("rolled_back")
    end

    it "rolls back AR changes" do
      txn.start!
      txn.execute { TestRecord.create!(name: "will_be_rolled_back") }
      txn.rollback!

      expect(TestRecord.where(name: "will_be_rolled_back").count).to eq(0)
    end
  end

  describe "#expired?" do
    it "returns false when within timeout" do
      expect(txn.expired?).to be false
    end

    it "returns true when past expiry" do
      expired_txn = described_class.new(timeout_seconds: 0)
      sleep(0.01)
      expect(expired_txn.expired?).to be true
    end
  end

  describe "#as_json" do
    it "returns a hash with transaction attributes" do
      json = txn.as_json
      expect(json[:id]).to eq(txn.id)
      expect(json[:state]).to eq("open")
      expect(json[:timeout_seconds]).to eq(10)
      expect(json[:expires_at]).to be_a(String)
      expect(json[:created_at]).to be_a(String)
    end
  end
end
