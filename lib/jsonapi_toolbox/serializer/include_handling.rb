# frozen_string_literal: true

require "set"

module JsonapiToolbox
  module Serializer
    module IncludeHandling
      extend ActiveSupport::Concern

      # Thread-local storage key for tracking serializer expansion stack
      EXPANSION_STACK = :serializer_include_expansion_stack

      included do
        # Rails 4.2 compatible class_attribute declarations (no `default:` keyword)
        class_attribute :_raw_includes
        self._raw_includes = []

        class_attribute :_include_options
        self._include_options = []

        class_attribute :_includes_expanded
        self._includes_expanded = false

        # Stores overrides for this serializer's direct relationships.
        # Format: { api_name: :active_record_name_or_scope }
        class_attribute :include_overrides
        self.include_overrides = {}
      end

      class_methods do
        def allow_includes(*includes, recursive: false, prefix: nil)
          self._raw_includes += includes
          self._include_options << { includes: includes, recursive: recursive, prefix: prefix }
          self._includes_expanded = false
        end

        def allowed_includes
          expand_all_includes unless _includes_expanded
          @expanded_allowed_includes
        end

        # Define how to eager-load a specific relationship.
        # @param api_name [Symbol] The name of the relationship in the API.
        # @param active_record_include [Symbol, Hash, Proc] The value to use in the ActiveRecord .includes() call.
        def define_include_override(api_name, active_record_include)
          self.include_overrides = include_overrides.merge(api_name.to_sym => active_record_include)
        end

        # Translates requested API include paths into a single, efficient ActiveRecord includes hash.
        def build_activerecord_includes(requested_paths = [])
          valid_paths = requested_paths.map(&:to_s) & allowed_includes.map(&:to_s)
          return {} if valid_paths.empty?

          # 1. Build a nested hash representing the shape of the API includes.
          # e.g., ["a.b", "a.c"] -> { a: { b: {}, c: {} } }
          api_shape = valid_paths.reduce({}) do |hash, path|
            hash.deep_merge(
              path.split(".").map(&:to_sym).reverse.reduce({}) { |h, p| { p => h } }
            )
          end

          # 2. Recursively traverse the shape, translating API names to AR instructions.
          translate_api_shape_to_ar_includes(api_shape, self)
        end

        private

        # Recursive helper to perform the translation.
        def translate_api_shape_to_ar_includes(api_shape_node, serializer_class)
          return nil if serializer_class.nil? # Base case for relationships without a specified serializer.

          translated_node = {}

          api_shape_node.each do |api_name, nested_shape|
            # Find the relationship definition on the current serializer
            relationship = serializer_class.relationships_to_serialize[api_name]
            raise "Relationship '#{api_name}' not defined on #{serializer_class.name}" unless relationship

            # Get the override if it exists, otherwise default to the API name.
            ar_instruction = serializer_class.include_overrides[api_name]
            next if ar_instruction == false

            ar_instruction = api_name if ar_instruction.nil?

            # If there's a nested shape to process, recurse.
            if nested_shape.present?
              next_serializer = relationship.static_serializer
              recursed_includes = translate_api_shape_to_ar_includes(nested_shape, next_serializer)

              # Combine the current instruction with the nested ones.
              # Handles cases where the instruction is already a hash (e.g., for scopes).
              if ar_instruction.is_a?(Hash)
                ar_instruction.values.first.merge!(recursed_includes) if recursed_includes.present?
                translated_node.merge!(ar_instruction)
              else
                translated_node[ar_instruction] = recursed_includes
              end
            else
              # Base case of the recursion (no deeper includes).
              if ar_instruction.is_a?(Hash)
                translated_node.merge!(ar_instruction)
              else
                translated_node[ar_instruction] = {} # Use empty hash for leaf nodes
              end
            end
          end

          translated_node
        end

        # Expands includes with recursive and prefix options
        def expand_includes(includes, recursive:, prefix:, expansion_context: nil)
          prefixes = Array.wrap(prefix).map(&:to_s).presence || [ "" ]

          prefixes.flat_map do |pfx|
            pfx = "#{pfx}_" unless pfx.empty?

            includes.flat_map do |inc|
              if recursive
                expand_recursive(inc.to_sym, pfx, visited: Set.new, path: [], expansion_context: expansion_context)
              else
                [ "#{pfx}#{inc}" ]
              end
            end
          end.uniq
        end

        # Recursively expands includes through serializer relationships
        def expand_recursive(relationship, prefix, visited:, path:, expansion_context: nil)
          full_name = "#{prefix}#{relationship}"
          current_path = path + [ self ]

          # Prevent infinite loops - if we've seen this serializer in our current path,
          # add it as a leaf but don't recurse further
          return [ full_name ] if visited.include?(self)

          # Check if relationships_to_serialize exists and has the relationship
          return [ full_name ] unless relationships_to_serialize&.key?(relationship)

          rel = relationships_to_serialize[relationship]
          return [ full_name ] unless rel&.respond_to?(:static_serializer) && rel.static_serializer

          child_serializer = rel.static_serializer

          # Allow shallow reference if we've seen this serializer in our ancestry
          return [ full_name ] if current_path.include?(child_serializer)

          # Get child includes and recursively expand them
          child_includes = []

          if child_serializer.respond_to?(:allowed_includes) && child_serializer.allowed_includes.any?
            child_includes = child_serializer.allowed_includes
          end

          # Recursively expand child includes, passing along the expansion context
          expanded_children = child_includes.flat_map do |child_inc|
            child_path = "#{full_name}.#{child_inc}"
            [ child_path ]
          end

          [ full_name ] + expanded_children
        end

        # Expands all stored include options when first accessed
        def expand_all_includes
          return if _includes_expanded

          # Get or initialize the thread-local expansion context
          # This tracks [serializer_class, relationship_name] pairs to detect TRUE circular dependencies
          expansion_context = Thread.current[EXPANSION_STACK] ||= []

          # Check if we're already expanding this exact serializer (circular dependency detected)
          if expansion_context.any? { |(serializer, _)| serializer == self }
            existing_entry = expansion_context.find { |(serializer, _)| serializer == self }

            Rails.logger.warn do
              "[IncludeHandling] Circular dependency detected: #{self.name} is already being expanded " \
              "via #{existing_entry[1]}. Current expansion path: " \
              "#{expansion_context.map { |(s, rel)| "#{s.name}.#{rel}" }.join(" -> ")}"
            end

            # Return non-recursive includes only to break the cycle gracefully
            all_paths = []
            _include_options.each do |option|
              unless option[:recursive]
                paths = expand_includes(option[:includes], recursive: false, prefix: option[:prefix], expansion_context: expansion_context)
                all_paths.concat(paths.map(&:to_sym))
              end
            end

            @expanded_allowed_includes = all_paths.uniq
            self._includes_expanded = true
            self._raw_includes = []
            self._include_options = []

            return
          end

          # Mark that we're expanding this serializer (with all its relationships)
          expansion_context.push([ self, :expanding_all ])

          begin
            all_paths = []

            _include_options.each do |option|
              paths = expand_includes(option[:includes], recursive: option[:recursive], prefix: option[:prefix], expansion_context: expansion_context)
              all_paths.concat(paths.map(&:to_sym))
            end

            @expanded_allowed_includes = all_paths.uniq
            self._includes_expanded = true

            # Clean up temporary storage to free memory
            self._raw_includes = []
            self._include_options = []
          ensure
            # Always remove this serializer from the stack when done
            expansion_context.pop
          end
        end
      end
    end
  end
end
