# frozen_string_literal: true

require "faraday"

module JsonapiToolbox
  module Client
    # Surgery on a Faraday::RackBuilder's adapter that works across every
    # Faraday this gem supports (0.17 → 2.x). Everything version-sensitive
    # about *adapters* lives here so Client::Base can read as plain intent.
    #
    # Where the adapter lives:
    #   0.x       just the last Handler in `@handlers`; `builder.adapter` with
    #             no arguments is a mutator that raises ArgumentError, and
    #             with arguments it *appends* via `use`, resolving symbols only.
    #   1.x/2.x   a separate `@adapter` slot; `builder.adapter` with no
    #             arguments reads it, with a class/symbol overwrites it.
    #
    # How a Handler stores its arguments (no public reader on any version):
    #   0.x       `@args`, `@block`
    #   1.x/2.x   `@args`, `@kwargs`, `@block`
    # and adapter options arrive either as a trailing positional Hash
    # (json_api_client's `adapter: [:sym, {..}]` form, on any version) or as
    # keywords (Faraday's documented `builder.adapter :sym, key: v` form).
    module FaradayBuilder
      module_function

      # True when this Faraday keeps the adapter in a dedicated slot.
      def adapter_slot?(builder)
        builder.adapter
        true
      rescue ArgumentError
        false
      end

      # The builder's adapter Handler (or nil), wherever it is kept.
      def adapter_handler(builder)
        return builder.adapter if adapter_slot?(builder)

        builder.handlers.reverse.find { |h| h.klass <= Faraday::Adapter }
      end

      # Splits a Handler into [positional args, options Hash, config block],
      # normalising positional-Hash and keyword options into one Hash so
      # callers can merge into it.
      def handler_parts(handler)
        args = (handler.instance_variable_get(:@args) || []).dup
        opts = handler.instance_variable_get(:@kwargs) || {}
        opts = args.pop.merge(opts) if args.last.is_a?(Hash)
        [args, opts, handler.instance_variable_get(:@block)]
      end

      # Installs `existing.klass` on `builder` with new args/options/block in
      # place of `existing`. Options go as a trailing positional Hash, which
      # every adapter's `initialize(app, opts = {}, &block)` accepts on every
      # Ruby we support (no kwargs splat, so no Ruby 2.6/2.7 empty-`**{}`
      # quirks).
      def replace_adapter!(builder, existing, args, opts, block)
        adapter_args = opts.empty? ? args : args + [opts]
        if adapter_slot?(builder)
          builder.adapter(existing.klass, *adapter_args, &block)
        else
          builder.handlers.delete_if { |h| h.equal?(existing) }
          builder.use(existing.klass, *adapter_args, &block)
        end
      end
    end
  end
end
