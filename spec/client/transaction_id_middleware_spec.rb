# frozen_string_literal: true

require "spec_helper"
require "jsonapi_toolbox/client"

RSpec.describe JsonapiToolbox::Client::TransactionIdMiddleware do
  let(:app) { ->(env) { env } }
  let(:middleware) { described_class.new(app) }
  let(:env) { Faraday::Env.from(request_headers: {}) }

  after { Thread.current[:jsonapi_toolbox_transaction_id] = nil }

  it "adds the X-Transaction-ID header when the thread-local is set" do
    Thread.current[:jsonapi_toolbox_transaction_id] = "abc-123"
    middleware.call(env)
    expect(env.request_headers["X-Transaction-ID"]).to eq("abc-123")
  end

  it "does not set the header when no transaction is open" do
    middleware.call(env)
    expect(env.request_headers).not_to have_key("X-Transaction-ID")
  end

  it "preserves a header that was already set explicitly" do
    env.request_headers["X-Transaction-ID"] = "explicit"
    Thread.current[:jsonapi_toolbox_transaction_id] = "implicit"
    middleware.call(env)
    expect(env.request_headers["X-Transaction-ID"]).to eq("explicit")
  end

  it "does not leak thread-local state across threads" do
    Thread.current[:jsonapi_toolbox_transaction_id] = "main-thread"

    other_env = Faraday::Env.from(request_headers: {})
    Thread.new { middleware.call(other_env) }.join

    expect(other_env.request_headers).not_to have_key("X-Transaction-ID")
  end

  it "is registered on the Client::Base connection stack" do
    klass = Class.new(JsonapiToolbox::Client::Base) do
      self.site = "https://example.com/api/"
    end

    handlers = klass.connection.faraday.builder.handlers
    expect(handlers).to include(described_class)
  end
end
