# frozen_string_literal: true

require "singleton"
require "json_api_client"

require "jsonapi_toolbox/transaction/errors"
require "jsonapi_toolbox/transaction/held_transaction"
require "jsonapi_toolbox/transaction/manager"
require "jsonapi_toolbox/transaction/serializer"
require "jsonapi_toolbox/controller/transaction_aware"
require "jsonapi_toolbox/controller/transactions_actions"
require "jsonapi_toolbox/client/service_token_middleware"
require "jsonapi_toolbox/client/base"
require "jsonapi_toolbox/client/transaction"

module JsonapiToolbox
  module Transaction
    class Configuration
      attr_accessor :max_concurrent, :default_timeout, :max_timeout, :reaper_interval

      def initialize
        @max_concurrent = 10
        @default_timeout = 30
        @max_timeout = 60
        @reaper_interval = 5
      end
    end

    class << self
      attr_writer :logger

      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield(configuration)
      end

      def logger
        @logger
      end

      def reset_configuration!
        @configuration = Configuration.new
      end
    end
  end
end
