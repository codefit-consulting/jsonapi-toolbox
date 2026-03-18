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
        super
      end
    end
  end
end
