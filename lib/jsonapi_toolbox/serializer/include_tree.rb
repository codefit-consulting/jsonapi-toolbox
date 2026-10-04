# frozen_string_literal: true

module JsonapiToolbox
  module Serializer
    # Parses ?include= values into a tree, and checks a tree against the
    # serializers one segment at a time. A tree is a nested hash of
    # relationship names, so "room_types.rates,supplier" becomes
    # { room_types: { rates: {} }, supplier: {} }.
    module IncludeTree
      class << self
        def parse(value)
          paths(value).each_with_object({}) do |path, tree|
            path.split(".", -1).reduce(tree) { |node, segment| node[segment.to_sym] ||= {} }
          end
        end

        # The distinct paths in an include value, without surrounding spaces.
        def paths(value)
          Array(value).flat_map { |part| part.to_s.split(",") }.map(&:strip).reject(&:empty?).uniq
        end

        # Raises Errors::InvalidIncludeError at the first segment of `tree` that
        # cannot be served from `serializer`, and Errors::IncludeDeclarationError
        # when a relationship's serializer class cannot be resolved.
        def validate!(serializer, tree, max_depth: JsonapiToolbox::Serializer.configuration.max_include_depth)
          walk(serializer, tree, [], max_depth)
          true
        end

        # { "type" => serializer } for the root serializer and every serializer
        # the tree reaches, as sparse fieldsets need.
        def serializers_by_type(serializer, tree)
          types = { type_of(serializer).to_s => serializer }
          collect_types(serializer, tree, types)
          types
        end

        private

        def walk(serializer, tree, prefix, max_depth)
          tree.each do |name, subtree|
            path = prefix + [ name ]
            raise too_deep(path, max_depth) if path.size > max_depth

            relationship = IncludeHandling.relationships_of(serializer)[name]
            raise not_a_relationship(serializer, path) unless relationship
            raise not_allowed(serializer, path) unless IncludeHandling.includable?(serializer, name)

            target = IncludeHandling.static_serializer!(serializer, name, relationship)
            next if subtree.empty?
            raise chosen_per_record(path) unless target

            walk(target, subtree, path, max_depth)
          end
        end

        def collect_types(serializer, tree, types)
          tree.each do |name, subtree|
            relationship = IncludeHandling.relationships_of(serializer)[name]
            target = relationship && IncludeHandling.static_serializer_of(relationship)
            next unless target

            types[type_of(target).to_s] ||= target
            collect_types(target, subtree, types)
          end
        end

        def not_a_relationship(serializer, path)
          error(path, %("#{path.last}" is not a relationship of #{type_of(serializer)}.), serializer)
        end

        def not_allowed(serializer, path)
          error(path, %("#{path.last}" cannot be included from #{type_of(serializer)}.), serializer)
        end

        def too_deep(path, max_depth)
          error(path, "Include paths can have at most #{max_depth} segments.")
        end

        def chosen_per_record(path)
          error(path, %("#{path.last}" can hold records of several types, so nothing can be included below it.))
        end

        def error(path, reason, serializer = nil)
          includable = serializer ? IncludeHandling.includable_names(serializer).map(&:to_s) : []
          message = %(Invalid include "#{path.join(".")}": #{reason})
          if serializer
            message += includable.any? ? " Includable here: #{includable.join(", ")}." : " Nothing can be included here."
          end

          JsonapiToolbox::Errors::InvalidIncludeError.new(
            message, path: path.join("."), segment: path.last.to_s, includable: includable
          )
        end

        # Errors name the JSON:API type, which clients know.
        def type_of(serializer)
          serializer.respond_to?(:record_type) && serializer.record_type ? serializer.record_type : serializer.name
        end
      end
    end
  end
end
