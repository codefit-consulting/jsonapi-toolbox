# frozen_string_literal: true

require "spec_helper"
require "jsonapi_toolbox/client"
require "faraday/adapter/test"

# Covers README §3 (client half): a response whose meta.transaction_reaped is
# set raises a typed TransactionReaped naming the transaction, instead of the
# generic json_api_client NotFound that string-scrapes the resource URL.
RSpec.describe JsonapiToolbox::Client::TransactionReapedMiddleware do
  def build_stack(status:, body:)
    Faraday.new do |b|
      # Mirror json_api_client's ordering: Status (raises NotFound on 404) is
      # OUTER; our middleware runs after JSON parse and before Status raises.
      b.use JsonApiClient::Middleware::Status, {}
      b.use described_class
      b.response :json
      b.adapter :test do |stub|
        stub.get("/x") { [status, { "Content-Type" => "application/vnd.api+json" }, body] }
      end
    end
  end

  let(:reaped_body) do
    {
      errors: [{ status: "404", title: "Transaction abc was reaped", detail: "Transaction abc was reaped" }],
      meta: { transaction_id: "abc", transaction_reaped: true, reason: "lease_expired" }
    }.to_json
  end

  let(:plain_404_body) do
    { errors: [{ status: "404", title: "Resource not found" }] }.to_json
  end

  it "raises a typed TransactionReaped carrying the txn id and reason" do
    conn = build_stack(status: 404, body: reaped_body)

    expect { conn.get("/x") }.to raise_error(JsonapiToolbox::Client::TransactionReaped) do |e|
      expect(e.transaction_id).to eq("abc")
      expect(e.reason).to eq("lease_expired")
      expect(e.message).to include("abc")
      expect(e.message).not_to include("Resource not found")
    end
  end

  it "is a NotFound subclass, so existing rescue NotFound paths still catch it" do
    conn = build_stack(status: 404, body: reaped_body)
    expect { conn.get("/x") }.to raise_error(JsonApiClient::Errors::NotFound)
  end

  it "leaves a plain 404 (no reaped meta) to raise the generic NotFound" do
    conn = build_stack(status: 404, body: plain_404_body)
    expect { conn.get("/x") }.to raise_error(JsonApiClient::Errors::NotFound) do |e|
      expect(e).not_to be_a(JsonapiToolbox::Client::TransactionReaped)
    end
  end

  it "is installed on the Client::Base connection stack" do
    klass = Class.new(JsonapiToolbox::Client::Base) do
      self.site = "https://example.com/api/"
    end
    handlers = klass.connection.faraday.builder.handlers
    expect(handlers).to include(described_class)
  end
end
