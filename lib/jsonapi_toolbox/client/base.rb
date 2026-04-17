# frozen_string_literal: true

module JsonapiToolbox
  module Client
    class Base < JsonApiClient::Resource
      self.json_key_format = :underscored_key

      TRANSACTION_CONNECTION_KEY = :jsonapi_toolbox_transaction_connection

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

      # Routes request-time lookups through a transaction-scoped connection
      # when one is set on the current thread. json_api_client's Requestor
      # calls klass.connection (no args, no block) on every request; by
      # intercepting that path we pin every resource used inside a
      # within_transaction block to a single Faraday connection (and thus
      # a single TCP socket, and thus a single server worker).
      def self.connection(rebuild = false, &block)
        thread_conn = Thread.current[TRANSACTION_CONNECTION_KEY]
        return thread_conn if thread_conn && !rebuild && !block_given?

        super
      end

      # Builds a standalone JsonApiClient::Connection that mirrors this
      # class's shared connection_object (same site, middleware stack, and
      # adapter) but owns its own socket pool. Used by
      # Transaction.within_transaction to give each held transaction a
      # dedicated TCP socket for worker affinity.
      def self.build_dedicated_connection
        source = connection(true) if connection_object.nil?
        source ||= connection_object

        options = connection_options.dup
        if JsonapiToolbox::Client.configuration.persistent_connections
          options[:adapter] = :net_http_persistent
        end

        dedicated = connection_class.new(options.merge(site: site))
        clone_middleware_stack(from: source, to: dedicated)
        dedicated
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

      # Copies the Faraday middleware stack AND adapter from one
      # JsonApiClient::Connection onto another. The Handler wrappers are
      # immutable metadata (class + args + block), so sharing them across
      # builders is safe.
      def self.clone_middleware_stack(from:, to:)
        src_builder = from.faraday.builder
        dst_builder = to.faraday.builder

        dst_builder.handlers.replace(src_builder.handlers.dup)

        src_adapter = src_builder.adapter
        return unless src_adapter

        args = src_adapter.instance_variable_get(:@args) || []
        kwargs = src_adapter.instance_variable_get(:@kwargs) || {}
        block = src_adapter.instance_variable_get(:@block)
        dst_builder.adapter(src_adapter.klass, *args, **kwargs, &block)
      end
      private_class_method :clone_middleware_stack
    end
  end
end
