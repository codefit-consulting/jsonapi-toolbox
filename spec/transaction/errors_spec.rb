# frozen_string_literal: true

require "spec_helper"
require "jsonapi_toolbox/transaction"

RSpec.describe JsonapiToolbox::Transaction::Errors do
  describe JsonapiToolbox::Transaction::Errors::NotFoundError do
    it "stores the transaction ID" do
      error = described_class.new("abc-123")
      expect(error.transaction_id).to eq("abc-123")
      expect(error.message).to include("abc-123")
    end
  end

  describe JsonapiToolbox::Transaction::Errors::ExpiredError do
    it "stores the transaction ID" do
      error = described_class.new("abc-123")
      expect(error.transaction_id).to eq("abc-123")
      expect(error.message).to include("abc-123")
    end
  end

  describe JsonapiToolbox::Transaction::Errors::ConcurrencyLimitError do
    it "stores the limit" do
      error = described_class.new(10)
      expect(error.limit).to eq(10)
      expect(error.message).to include("10")
    end
  end

  describe JsonapiToolbox::Transaction::Errors::OperationError do
    it "wraps the original error and tracks rollback state" do
      original = StandardError.new("something went wrong")
      error = described_class.new(original, transaction_rolled_back: false)

      expect(error.original_error).to eq(original)
      expect(error.transaction_rolled_back).to eq(false)
      expect(error.message).to eq("something went wrong")
    end
  end
end
