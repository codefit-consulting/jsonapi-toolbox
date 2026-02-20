# frozen_string_literal: true

require "spec_helper"
require "jsonapi_toolbox/transaction"

RSpec.describe JsonapiToolbox::Client::TransactionClient do
  let(:base_url) { "https://example.com/api/internal" }
  let(:token) { "test-token" }
  let(:client) { described_class.new(base_url: base_url, token: token) }

  let(:create_response_body) do
    {
      data: {
        type: "transactions",
        id: "abc-123",
        attributes: {
          state: "open",
          timeout_seconds: 30,
          expires_at: "2026-02-20T10:30:30Z"
        }
      }
    }.to_json
  end

  let(:commit_response_body) do
    {
      data: {
        type: "transactions",
        id: "abc-123",
        attributes: {
          state: "committed",
          timeout_seconds: 30,
          expires_at: "2026-02-20T10:30:30Z"
        }
      }
    }.to_json
  end

  before do
    stubs = Faraday::Adapter::Test::Stubs.new
    @stubs = stubs

    allow(Faraday).to receive(:new).and_wrap_original do |method, *args, &block|
      method.call(*args) do |f|
        block.call(f) if block
        f.adapter :test, stubs
      end
    end
  end

  describe "#create" do
    it "sends a POST to /transactions and returns parsed attributes" do
      @stubs.post("/transactions") { [201, {}, create_response_body] }

      result = client.create(timeout_seconds: 30)
      expect(result["id"]).to eq("abc-123")
      expect(result["state"]).to eq("open")
    end
  end

  describe "#commit" do
    it "sends a PATCH to /transactions/:id/commit" do
      @stubs.patch("/transactions/abc-123/commit") { [200, {}, commit_response_body] }

      result = client.commit("abc-123")
      expect(result["state"]).to eq("committed")
    end
  end

  describe "#rollback" do
    it "sends a PATCH to /transactions/:id/rollback" do
      rollback_body = {
        data: {
          type: "transactions", id: "abc-123",
          attributes: { state: "rolled_back", timeout_seconds: 30 }
        }
      }.to_json
      @stubs.patch("/transactions/abc-123/rollback") { [200, {}, rollback_body] }

      result = client.rollback("abc-123")
      expect(result["state"]).to eq("rolled_back")
    end
  end

  describe "#find" do
    it "sends a GET to /transactions/:id" do
      @stubs.get("/transactions/abc-123") { [200, {}, create_response_body] }

      result = client.find("abc-123")
      expect(result["id"]).to eq("abc-123")
    end
  end

  describe "error handling" do
    it "raises NotFoundError on 404" do
      error_body = { errors: [{ status: "404", detail: "not found" }] }.to_json
      @stubs.get("/transactions/missing") { [404, {}, error_body] }

      expect {
        client.find("missing")
      }.to raise_error(JsonapiToolbox::Transaction::Errors::NotFoundError)
    end

    it "raises ExpiredError on 410" do
      error_body = { errors: [{ status: "410", detail: "expired" }] }.to_json
      @stubs.patch("/transactions/expired/commit") { [410, {}, error_body] }

      expect {
        client.commit("expired")
      }.to raise_error(JsonapiToolbox::Transaction::Errors::ExpiredError)
    end

    it "raises ConcurrencyLimitError on 429" do
      error_body = { errors: [{ status: "429", detail: "too many" }] }.to_json
      @stubs.post("/transactions") { [429, {}, error_body] }

      expect {
        client.create
      }.to raise_error(JsonapiToolbox::Transaction::Errors::ConcurrencyLimitError)
    end
  end
end
