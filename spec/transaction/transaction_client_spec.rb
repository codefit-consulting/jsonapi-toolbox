# frozen_string_literal: true

require "spec_helper"
require "jsonapi_toolbox/transaction"

RSpec.describe JsonapiToolbox::Client::Transaction do
  # Concrete subclass with site set, as apps would define
  let(:resource_class) do
    Class.new(described_class) do
      self.site = "https://example.com/api/internal/"
      configure_service_token "test-token"
    end
  end

  let(:open_transaction_body) do
    {
      "data" => {
        "type" => "transactions",
        "id" => "abc-123",
        "attributes" => {
          "state" => "open",
          "timeout_seconds" => 30,
          "expires_at" => "2026-02-20T10:30:30Z"
        }
      }
    }.to_json
  end

  let(:committed_body) do
    {
      "data" => {
        "type" => "transactions",
        "id" => "abc-123",
        "attributes" => {
          "state" => "committed",
          "timeout_seconds" => 30,
          "expires_at" => "2026-02-20T10:30:30Z"
        }
      }
    }.to_json
  end

  let(:rolled_back_body) do
    {
      "data" => {
        "type" => "transactions",
        "id" => "abc-123",
        "attributes" => {
          "state" => "rolled_back",
          "timeout_seconds" => 30,
          "expires_at" => "2026-02-20T10:30:30Z"
        }
      }
    }.to_json
  end

  describe "resource behaviour" do
    it "inherits from JsonapiToolbox::Client::Base" do
      expect(described_class.superclass).to eq(JsonapiToolbox::Client::Base)
    end
  end

  describe "#open?" do
    it "returns true when state is open" do
      txn = described_class.new(state: "open")
      expect(txn.open?).to be true
    end

    it "returns false when state is committed" do
      txn = described_class.new(state: "committed")
      expect(txn.open?).to be false
    end
  end
end
