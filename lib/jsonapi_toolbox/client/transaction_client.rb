# frozen_string_literal: true

require "faraday"
require "json"

module JsonapiToolbox
  module Client
    # HTTP client for managing held transactions on a remote app.
    # Uses raw Faraday because commit/rollback are non-standard REST
    # actions that don't map well to json_api_client.
    #
    # Usage:
    #
    #   client = TransactionClient.new(
    #     base_url: "https://v1.example.com/api/internal",
    #     token: -> { ServiceToken.current }
    #   )
    #
    #   txn = client.create(timeout_seconds: 30)
    #   # ... make API calls with X-Transaction-ID: txn["id"] ...
    #   client.commit(txn["id"])
    #
    class TransactionClient
      attr_reader :base_url

      def initialize(base_url:, token: nil)
        @base_url = base_url.chomp("/")
        @token_provider = token.respond_to?(:call) ? token : -> { token }
      end

      # Creates a held transaction on the remote app.
      # Returns parsed attributes hash: { "id" => "...", "state" => "open", ... }
      def create(timeout_seconds: nil)
        body = {
          data: {
            type: "transactions",
            attributes: { timeout_seconds: timeout_seconds }.compact
          }
        }
        response = connection.post("#{transactions_path}", body.to_json)
        handle_response(response)
      end

      # Commits a held transaction. Returns parsed attributes hash.
      def commit(transaction_id)
        response = connection.patch("#{transactions_path}/#{transaction_id}/commit")
        handle_response(response)
      end

      # Rolls back a held transaction. Returns parsed attributes hash.
      def rollback(transaction_id)
        response = connection.patch("#{transactions_path}/#{transaction_id}/rollback")
        handle_response(response)
      end

      # Returns the status of a held transaction.
      def find(transaction_id)
        response = connection.get("#{transactions_path}/#{transaction_id}")
        handle_response(response)
      end

      # Lists active held transactions (monitoring).
      def list
        response = connection.get(transactions_path)
        parsed = JSON.parse(response.body)
        parsed["data"].map { |d| extract_resource(d) }
      end

      # Convenience method: opens a transaction, yields the ID, and
      # commits on success or rolls back on failure. Sets X-Transaction-ID
      # on all json_api_client calls within the block via with_headers.
      #
      #   client.within_transaction do |txn_id|
      #     SomeResource.create!(name: "test")  # automatically gets the header
      #   end
      #
      def within_transaction(timeout_seconds: nil, &block)
        txn = create(timeout_seconds: timeout_seconds)
        txn_id = txn["id"]

        begin
          result = JsonApiClient::Resource.with_headers("X-Transaction-ID" => txn_id, &block)
          commit(txn_id)
          result
        rescue => e
          rollback(txn_id) rescue nil
          raise
        end
      end

      private

      def transactions_path
        "/transactions"
      end

      def connection
        token_provider = @token_provider
        @connection ||= Faraday.new(url: @base_url) do |f|
          f.headers["Content-Type"] = "application/vnd.api+json"
          f.headers["Accept"] = "application/vnd.api+json"
          f.use JsonapiToolbox::Client::ServiceTokenMiddleware, token_provider: token_provider
          f.adapter Faraday.default_adapter
        end
      end

      def handle_response(response)
        case response.status
        when 200, 201
          parsed = JSON.parse(response.body)
          extract_resource(parsed["data"])
        when 404
          raise Transaction::Errors::NotFoundError.new(extract_error_detail(response))
        when 410
          raise Transaction::Errors::ExpiredError.new(extract_error_detail(response))
        when 429
          raise Transaction::Errors::ConcurrencyLimitError.new(0)
        else
          raise Transaction::Errors::TransactionError,
            "Remote transaction error (#{response.status}): #{response.body}"
        end
      end

      def extract_resource(data)
        attrs = (data["attributes"] || {}).dup
        attrs["id"] = data["id"]
        attrs
      end

      def extract_error_detail(response)
        parsed = JSON.parse(response.body)
        parsed.dig("errors", 0, "detail") || response.body
      rescue JSON::ParserError
        response.body
      end
    end
  end
end
