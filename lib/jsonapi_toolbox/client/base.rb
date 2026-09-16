# frozen_string_literal: true

module JsonapiToolbox
  module Client
    class Base < JsonApiClient::Resource
      self.json_key_format = :underscored_key

      # Key for the thread-local pending-transaction marker set by
      # Transaction.within_transaction. The value is a mutable hash that
      # carries the Transaction subclass, requested timeout, the
      # lazy-built dedicated connection, and the materialised txn (once
      # the first non-/transactions request triggers its creation).
      PENDING_TRANSACTION_KEY = :jsonapi_toolbox_pending_transaction

      # Key for the thread-local transaction id, set once the pending
      # transaction has been materialised. Read by TransactionIdMiddleware
      # to attach X-Transaction-ID to outgoing requests.
      TRANSACTION_ID_KEY = :jsonapi_toolbox_transaction_id

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
        install_transaction_reaped_middleware!(result)
        result
      end

      # Routes request-time lookups through a transaction-scoped connection
      # when a within_transaction block is active on the current thread.
      # json_api_client's Requestor calls klass.connection (no args, no
      # block) on every request; by intercepting that path we pin every
      # resource used inside a block to a single Faraday connection (and
      # thus a single TCP socket, and thus a single server worker).
      #
      # The dedicated connection is built lazily on first access — blocks
      # that make no remote requests allocate nothing beyond the pending
      # marker hash.
      def self.connection(rebuild = false, &block)
        pending = Thread.current[PENDING_TRANSACTION_KEY]
        if pending && !rebuild && !block_given?
          pending[:connection] ||= pending[:transaction_class].build_dedicated_connection(pending)
          return pending[:connection]
        end

        super
      end

      # Builds a standalone JsonApiClient::Connection that mirrors this
      # class's shared connection_object (same site, middleware stack, and
      # adapter) but owns its own single socket. Used by
      # Transaction.within_transaction to give each held transaction a
      # dedicated TCP socket for worker affinity. `pending` is the block's
      # marker hash; its transaction_class decides how long the socket may
      # sit idle (see pin_persistent_socket!).
      def self.build_dedicated_connection(pending)
        source = connection(true) if connection_object.nil?
        source ||= connection_object

        options = connection_options.dup
        if JsonapiToolbox::Client.configuration.persistent_connections
          options[:adapter] = :net_http_persistent
        end

        dedicated = connection_class.new(options.merge(site: site))
        clone_middleware_stack(from: source, to: dedicated)
        install_request_serializer_middleware!(dedicated)
        pin_persistent_socket!(dedicated) do
          pending[:transaction_class].pinned_socket_idle_timeout(pending)
        end
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

      # Ensures TransactionReapedMiddleware is present exactly once, so any
      # response carrying meta.transaction_reaped raises the typed
      # TransactionReaped instead of a generic NotFound.
      def self.install_transaction_reaped_middleware!(conn)
        return unless conn
        handlers = conn.faraday.builder.handlers
        return if handlers.include?(TransactionReapedMiddleware)

        conn.use(TransactionReapedMiddleware)
      end
      private_class_method :install_transaction_reaped_middleware!

      # Serialises all requests on the dedicated (worker-pinned) connection so
      # the automatic heartbeat thread can never overlap a real request on the
      # shared socket. Added once, with a fresh per-connection mutex.
      def self.install_request_serializer_middleware!(conn)
        return unless conn
        handlers = conn.faraday.builder.handlers
        return if handlers.include?(RequestSerializerMiddleware)

        conn.use(RequestSerializerMiddleware, mutex: Mutex.new)
      end
      private_class_method :install_request_serializer_middleware!

      # Copies the Faraday middleware stack AND adapter from one
      # JsonApiClient::Connection onto another. The Handler wrappers are
      # immutable metadata (class + args + block), so sharing them across
      # builders is safe.
      #
      # Faraday stores the adapter in different places across major
      # versions: on 0.x it lives inside `@handlers` (already copied by the
      # `handlers.replace` below), and `builder.adapter` with no args is a
      # mutator that raises ArgumentError. On 1.x/2.x `@adapter` is a
      # separate slot and `builder.adapter` returns the current handler, so
      # we have to re-attach it explicitly on the destination.
      def self.clone_middleware_stack(from:, to:)
        src_builder = from.faraday.builder
        dst_builder = to.faraday.builder

        dst_builder.handlers.replace(src_builder.handlers.dup)

        src_adapter = FaradayBuilder.adapter_handler(src_builder)
        return unless src_adapter

        FaradayBuilder.replace_adapter!(dst_builder, src_adapter, *FaradayBuilder.handler_parts(src_adapter))
      end
      private_class_method :clone_middleware_stack

      # Reconfigures the dedicated connection's :net_http_persistent adapter
      # so the socket it pins to one receiver worker actually stays pinned:
      #
      # - `idle_timeout` (5 s by default in net-http-persistent) becomes
      #   whatever the block returns, re-evaluated on every request. Past
      #   that idle time the client transparently opens a *new* socket on
      #   the next request, which the receiver's next free worker accepts —
      #   one that has never seen the transaction. Transaction sizes it to
      #   the granted lease plus a grace, so the socket outlives the slot.
      # - `pool_size: 1`, so "the pin" is exactly one socket by construction
      #   rather than by the request serialiser happening to reuse the same
      #   pooled connection.
      #
      # Both go through the adapter's config block: json_api_client's
      # Connection calls `builder.adapter(*options)` with no block, and the
      # Net::HTTP::Persistent instance is only built on first request.
      # Faraday calls the block with that instance before every request,
      # which is what lets the timeout track the lease as it is granted.
      #
      # No-op unless the adapter actually is NetHttpPersistent (e.g.
      # persistent_connections disabled, or a test adapter swapped in).
      def self.pin_persistent_socket!(conn, &idle_timeout)
        builder = conn.faraday.builder
        handler = FaradayBuilder.adapter_handler(builder)
        return unless handler && handler.klass.name.to_s.end_with?("NetHttpPersistent")

        args, opts, inner = FaradayBuilder.handler_parts(handler)
        config = lambda do |http|
          inner&.call(http)
          http.idle_timeout = idle_timeout.call if http.respond_to?(:idle_timeout=)
        end

        FaradayBuilder.replace_adapter!(builder, handler, args, opts.merge(pool_size: 1), config)
      end
      private_class_method :pin_persistent_socket!
    end
  end
end
