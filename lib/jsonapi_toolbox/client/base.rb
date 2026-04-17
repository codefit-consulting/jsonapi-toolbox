# frozen_string_literal: true

module JsonapiToolbox
  module Client
    class Base < JsonApiClient::Resource
      self.json_key_format = :underscored_key

      def self.configure_service_token(token_or_proc)
        provider = token_or_proc.respond_to?(:call) ? token_or_proc : -> { token_or_proc }
        connection do |conn|
          conn.use ServiceTokenMiddleware, token_provider: provider
        end
      end

      def self._build_connection(rebuild = false)
        if JsonapiToolbox::Client.configuration.persistent_connections
          self.connection_options = connection_options.merge(adapter: :net_http_persistent)
        end
        result = super
        install_transaction_id_middleware!(result)
        result
      end

      # Ensures TransactionIdMiddleware is present on this class's Faraday
      # stack exactly once. Called from _build_connection so every subclass
      # gets the middleware on its own connection without requiring opt-in.
      def self.install_transaction_id_middleware!(conn)
        return unless conn
        handlers = conn.faraday.builder.handlers
        return if handlers.include?(TransactionIdMiddleware)

        conn.use(TransactionIdMiddleware)
      end
      private_class_method :install_transaction_id_middleware!
    end
  end
end
