# frozen_string_literal: true

require "json_api_client"
require "faraday/net_http_persistent"
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
