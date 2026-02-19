# frozen_string_literal: true

module JsonapiToolbox
  module Client
    class ServiceTokenMiddleware < Faraday::Middleware
      def initialize(app, options = {})
        super(app)
        @token_provider = options[:token_provider]
      end

      def call(env)
        token = @token_provider.respond_to?(:call) ? @token_provider.call : @token_provider
        env.request_headers["X-Service-Token"] = token
        @app.call(env)
      end
    end
  end
end
