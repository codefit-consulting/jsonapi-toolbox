# frozen_string_literal: true

require "spec_helper"
require "jsonapi_toolbox/client"
require "jsonapi_toolbox/transaction"
require "faraday/adapter/test"

# Covers the v0.2.0 laziness fix: Transaction.within_transaction no longer
# POSTs /transactions at block entry. It materialises on the first
# non-/transactions request through the middleware. Blocks that make no
# remote calls should issue zero requests.
RSpec.describe "Transaction.within_transaction laziness" do
  around do |ex|
    original = Faraday.default_adapter
    Faraday.default_adapter = :test
    JsonapiToolbox::Client.configure { |c| c.persistent_connections = false }
    ex.run
  ensure
    Faraday.default_adapter = original
    JsonapiToolbox::Client.reset_configuration!
  end

  let(:captured) { [] }
  let(:stubs) do
    s = Faraday::Adapter::Test::Stubs.new
    recorder = captured
    s.post("/api/transactions") do |env|
      recorder << [:post, env.url.path, env.request_headers.dup]
      json_response(txn_body)
    end
    s.patch("/api/transactions/txn-1") do |env|
      recorder << [:patch, env.url.path, env.request_headers.dup]
      json_response(patch_body(env))
    end
    s.post("/api/widgets") do |env|
      recorder << [:post, env.url.path, env.request_headers.dup]
      json_response(widget_body)
    end
    s
  end

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

  let(:txn_body) do
    { data: { type: "transactions", id: "txn-1",
              attributes: { state: "open", timeout_seconds: 30 } } }.to_json
  end

  let(:widget_body) do
    { data: { type: "widgets", id: "1", attributes: {} } }.to_json
  end

  def patch_body(env)
    state = JSON.parse(env.body).dig("data", "attributes", "state") || "committed"
    { data: { type: "transactions", id: "txn-1",
              attributes: { state: state, timeout_seconds: 30 } } }.to_json
  end

  def json_response(body)
    [200, { "Content-Type" => "application/vnd.api+json" }, body]
  end

  def paths
    captured.map { |method, path, _| "#{method.upcase} #{path}" }
  end

  describe "block with no remote calls" do
    it "issues zero HTTP requests" do
      transaction_class.within_transaction { }
      expect(captured).to be_empty
    end

    it "yields a LazyTransaction with state == 'not_opened'" do
      transaction_class.within_transaction do |txn|
        expect(txn).to be_a(JsonapiToolbox::Client::LazyTransaction)
        expect(txn.state).to eq("not_opened")
        expect(txn.id).to be_nil
        expect(txn).not_to be_materialized
        expect(txn).not_to be_open
      end
    end

    it "no-ops commit!/rollback! calls on the proxy" do
      expect do
        transaction_class.within_transaction do |txn|
          txn.commit!
          txn.rollback!
        end
      end.not_to raise_error

      expect(captured).to be_empty
    end
  end

  describe "block with a remote call" do
    it "materialises once: POST /transactions then POST /widgets then PATCH commit" do
      transaction_class.within_transaction do
        widget_class.create(name: "w")
        widget_class.create(name: "w2")
      end

      expect(paths).to eq([
        "POST /api/transactions",
        "POST /api/widgets",
        "POST /api/widgets",
        "PATCH /api/transactions/txn-1"
      ])

      # Commit PATCH should carry state=committed (vs rolled_back).
      patch_entry = captured.last
      expect(patch_entry.first).to eq(:patch)

      # POST /transactions carries no X-Transaction-ID (it's creating the txn).
      create_headers = captured.first[2]
      expect(create_headers["X-Transaction-ID"]).to be_nil

      # Every subsequent request carries the materialised id.
      captured[1..-1].each do |entry|
        expect(entry[2]["X-Transaction-ID"]).to eq("txn-1")
      end
    end

    it "reports a materialised LazyTransaction inside and after the block" do
      final_txn = nil
      transaction_class.within_transaction do |txn|
        widget_class.create(name: "w")
        expect(txn).to be_materialized
        expect(txn.id).to eq("txn-1")
        expect(txn.state).to eq("open")
        final_txn = txn
      end
      # After commit (on block exit), the underlying txn is still referenced.
      expect(final_txn.id).to eq("txn-1")
    end
  end

  describe "exception handling" do
    it "issues zero requests when the block raises before any remote call" do
      expect do
        transaction_class.within_transaction { raise "boom" }
      end.to raise_error("boom")

      expect(captured).to be_empty
    end

    it "rolls back when the block raises after a remote call" do
      expect do
        transaction_class.within_transaction do
          widget_class.create(name: "w")
          raise "boom"
        end
      end.to raise_error("boom")

      expect(paths).to eq([
        "POST /api/transactions",
        "POST /api/widgets",
        "PATCH /api/transactions/txn-1"
      ])
      expect(captured.last[2]["X-Transaction-ID"]).to eq("txn-1")
    end
  end

  describe "reentrancy" do
    it "joins the outer pending marker when the outer hasn't materialised yet" do
      transaction_class.within_transaction do
        transaction_class.within_transaction { }
        widget_class.create(name: "w")
      end

      expect(paths).to eq([
        "POST /api/transactions",
        "POST /api/widgets",
        "PATCH /api/transactions/txn-1"
      ])
    end

    it "joins the outer pending marker when the inner does the remote call" do
      transaction_class.within_transaction do
        transaction_class.within_transaction do
          widget_class.create(name: "w")
        end
      end

      expect(paths).to eq([
        "POST /api/transactions",
        "POST /api/widgets",
        "PATCH /api/transactions/txn-1"
      ])
    end

    it "yields the outer's LazyTransaction to inner blocks" do
      outer_id = nil
      inner_materialised = nil
      transaction_class.within_transaction do |outer|
        outer_id = outer.object_id
        transaction_class.within_transaction do |inner|
          # Same proxy semantics — both read from the same pending marker.
          expect(inner).to be_a(JsonapiToolbox::Client::LazyTransaction)
          widget_class.create(name: "w")
          inner_materialised = inner.materialized?
        end
      end
      expect(inner_materialised).to be true
      expect(outer_id).not_to be_nil
    end
  end

  describe "middleware guard" do
    it "does not recurse when Transaction.create fires from the middleware" do
      transaction_class.within_transaction do
        widget_class.create(name: "w")
      end

      create_entry = captured.find { |m, p, _| m == :post && p.end_with?("/transactions") }
      expect(create_entry).not_to be_nil
      expect(create_entry[2]["X-Transaction-ID"]).to be_nil
    end

    it "still attaches the header on the commit PATCH after materialisation" do
      transaction_class.within_transaction do
        widget_class.create(name: "w")
      end

      patch_entry = captured.find { |m, _, _| m == :patch }
      expect(patch_entry).not_to be_nil
      expect(patch_entry[2]["X-Transaction-ID"]).to eq("txn-1")
    end
  end

  describe "thread-local cleanup" do
    it "clears both markers on successful exit" do
      transaction_class.within_transaction { widget_class.create(name: "w") }
      expect(Thread.current[JsonapiToolbox::Client::Base::PENDING_TRANSACTION_KEY]).to be_nil
      expect(Thread.current[JsonapiToolbox::Client::Base::TRANSACTION_ID_KEY]).to be_nil
    end

    it "clears both markers when the block raises" do
      expect do
        transaction_class.within_transaction { raise "boom" }
      end.to raise_error("boom")

      expect(Thread.current[JsonapiToolbox::Client::Base::PENDING_TRANSACTION_KEY]).to be_nil
      expect(Thread.current[JsonapiToolbox::Client::Base::TRANSACTION_ID_KEY]).to be_nil
    end
  end
end
