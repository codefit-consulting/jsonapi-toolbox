# frozen_string_literal: true

require "spec_helper"
require "jsonapi_toolbox/transaction"
require "faraday/adapter/test"

RSpec.describe "within_transaction header propagation" do
  # Swap the default Faraday adapter for the test adapter so json_api_client's
  # Connection picks it up when it builds the Faraday stack.
  around do |ex|
    original = Faraday.default_adapter
    Faraday.default_adapter = :test
    JsonapiToolbox::Client.configure { |c| c.persistent_connections = false }
    ex.run
  ensure
    Faraday.default_adapter = original
    JsonapiToolbox::Client.reset_configuration!
  end

  let(:stubs) { Faraday::Adapter::Test::Stubs.new }

  let(:transaction_class) do
    s = stubs
    Class.new(JsonapiToolbox::Client::Transaction) do
      self.site = "https://example.com/api/"
      def self.resource_name
        "transaction"
      end
      connection do |conn|
        conn.faraday.builder.adapter :test, s
      end
    end
  end

  let(:widget_class) do
    s = stubs
    Class.new(JsonapiToolbox::Client::Base) do
      self.site = "https://example.com/api/"
      def self.resource_name
        "widget"
      end
      connection do |conn|
        conn.faraday.builder.adapter :test, s
      end
    end
  end

  # Headers observed on each captured request, in the order they were made.
  let(:captured_headers) { [] }

  let(:txn_body) do
    {
      data: {
        type: "transactions",
        id: "txn-1",
        attributes: { state: "open", timeout_seconds: 30 }
      }
    }.to_json
  end

  let(:committed_body) do
    {
      data: {
        type: "transactions",
        id: "txn-1",
        attributes: { state: "committed", timeout_seconds: 30 }
      }
    }.to_json
  end

  let(:widget_body) do
    {
      data: {
        type: "widgets",
        id: "1",
        attributes: { name: "x" }
      }
    }.to_json
  end

  def json_response(body)
    [200, { "Content-Type" => "application/vnd.api+json" }, body]
  end

  before do
    headers_log = captured_headers

    stubs.post("/api/transactions") do |env|
      headers_log << env.request_headers.dup
      json_response(txn_body)
    end

    stubs.patch("/api/transactions/txn-1") do |env|
      headers_log << env.request_headers.dup
      json_response(committed_body)
    end

    stubs.post("/api/widgets") do |env|
      headers_log << env.request_headers.dup
      json_response(widget_body)
    end
  end

  it "sends X-Transaction-ID on sibling resource requests inside the block" do
    # Force both classes (and their shared stubs) to be built before the block.
    transaction_class
    widget_class

    transaction_class.within_transaction do
      widget_class.create(name: "x")
    end

    # Order: POST /transactions (create), POST /widgets, PATCH /transactions/:id (commit)
    expect(captured_headers.length).to eq(3)

    create_txn_headers, widget_headers, commit_headers = captured_headers

    # Txn create itself does not need the header — it's creating the txn.
    expect(create_txn_headers["X-Transaction-ID"]).to be_nil

    # The sibling resource MUST carry the header — this is the regression case.
    expect(widget_headers["X-Transaction-ID"]).to eq("txn-1")

    # Commit PATCH runs before the ensure block clears the thread-local, so it
    # carries the header too (preserves prior behaviour).
    expect(commit_headers["X-Transaction-ID"]).to eq("txn-1")
  end

  it "does not send X-Transaction-ID outside a transaction block" do
    widget_class
    widget_class.create(name: "x")

    expect(captured_headers.length).to eq(1)
    expect(captured_headers.first["X-Transaction-ID"]).to be_nil
  end

  it "clears the header after the block, even on exception" do
    transaction_class
    widget_class

    stubs.patch("/api/transactions/txn-1") do |env|
      captured_headers << env.request_headers.dup
      json_response(
        {
          data: {
            type: "transactions",
            id: "txn-1",
            attributes: { state: "rolled_back", timeout_seconds: 30 }
          }
        }.to_json
      )
    end

    expect do
      transaction_class.within_transaction { raise "boom" }
    end.to raise_error("boom")

    expect(Thread.current[:jsonapi_toolbox_transaction_id]).to be_nil

    # A request made after the block should not carry the header.
    captured_headers.clear
    widget_class.create(name: "x")
    expect(captured_headers.first["X-Transaction-ID"]).to be_nil
  end
end
