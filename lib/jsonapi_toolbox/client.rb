# frozen_string_literal: true

require "json_api_client"

# Faraday 2.x extracted the :net_http_persistent adapter into a separate gem.
# Faraday 0.x/1.x ships it built-in. Try loading the extracted gem first;
# if unavailable the built-in adapter will be used.
begin
  require "faraday/net_http_persistent"
rescue LoadError
  # Built-in adapter available in Faraday < 2
end

require "jsonapi_toolbox/client/service_token_middleware"
require "jsonapi_toolbox/client/base"

module JsonapiToolbox
  module Client
    class Configuration
      attr_accessor :persistent_connections

      def initialize
        @persistent_connections = true
      end
    end

    class << self
      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield(configuration)
      end

      def reset_configuration!
        @configuration = Configuration.new
      end
    end
  end
end
