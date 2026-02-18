# frozen_string_literal: true

module JsonapiToolbox
  module Controller
    module Validation
      extend ActiveSupport::Concern

      included do
        jsonapi_body_actions = [ :create, :update ].select { |action| method_defined?(action) }
        before_action :validate_jsonapi_request, only: jsonapi_body_actions if jsonapi_body_actions.present?
        before_action :validate_includes, if: -> { params[:include] }
        before_action :validate_sparse_fieldsets, if: -> { params[:fields] }
      end

      private

      def validate_jsonapi_request
        document_hash = params.to_unsafe_h.slice("data")
        JSONAPI.parse_resource!(document_hash)
      rescue JSONAPI::Parser::InvalidDocument => e
        render_jsonapi_error(e)
      end

      def validate_includes
        return unless params[:include]

        requested_includes = params[:include].to_s.split(",").map(&:strip)
        allowed_includes = extract_allowed_includes(serializer_class).map(&:to_s)

        invalid_includes = requested_includes - allowed_includes
        if invalid_includes.any?
          raise JsonapiToolbox::Errors::InvalidIncludeError.new(invalid_includes, allowed_includes)
        end

        @validated_includes = requested_includes
      end

      def validate_sparse_fieldsets
        return unless params[:fields] && params[:fields].is_a?(ActionController::Parameters)

        allowed_includes = extract_allowed_includes(serializer_class)

        @validated_fields = {}

        params[:fields].each do |type, field_list|
          requested_fields = field_list.to_s.split(",").map(&:strip).map(&:to_sym)

          # Find the serializer for this type
          type_serializer = find_serializer_for_type(type, serializer_class, allowed_includes)

          if type_serializer.nil?
            # Skip validation for types that can't be included (not in allowed_includes)
            # This allows the JSON:API library to handle the error if needed
            next
          end

          # Extract allowed fields for this type's serializer (attributes only, no relationships)
          allowed_fields = extract_attributes(type_serializer)

          invalid_fields = requested_fields.map(&:to_s) - allowed_fields.map(&:to_s)
          if invalid_fields.any?
            raise JsonapiToolbox::Errors::InvalidFieldsError.new(invalid_fields, allowed_fields, type)
          end

          @validated_fields[type.to_sym] = requested_fields
        end
      end

      def extract_allowed_includes(serializer_class)
        # Use the explicitly defined allowed_includes if available
        if serializer_class.respond_to?(:allowed_includes) && serializer_class.allowed_includes.any?
          return serializer_class.allowed_includes
        end

        # Fallback to extracting basic relationships (no nested support)
        extract_basic_relationships(serializer_class)
      end

      def extract_basic_relationships(serializer_class)
        relationships = []

        if serializer_class.respond_to?(:relationships_to_serialize) && !serializer_class.relationships_to_serialize.nil?
          relationships = serializer_class.relationships_to_serialize.keys.map(&:to_s)
        end

        relationships
      end

      def find_serializer_for_type(type, main_serializer, allowed_includes)
        # First check if this is the main resource type
        main_type = extract_resource_type(main_serializer).to_s
        return main_serializer if type == main_type

        # Check if this type corresponds to any allowed include path
        # We need to traverse the relationship tree to find the serializer
        serializer_cache = { main_type => main_serializer }

        allowed_includes.each do |include_path|
          # Split nested includes like "author.address" into ["author", "address"]
          path_parts = include_path.split(".")
          current_serializer = main_serializer
          current_type = main_type

          path_parts.each_with_index do |relationship_name, _index|
            # Get the serializer for this relationship
            if current_serializer.respond_to?(:relationships_to_serialize) && !current_serializer.relationships_to_serialize.nil?
              rel_config = current_serializer.relationships_to_serialize[relationship_name.to_sym]

              if rel_config&.respond_to?(:static_serializer) && rel_config.static_serializer
                current_serializer = rel_config.static_serializer
                current_type = extract_resource_type(current_serializer).to_s

                # Cache this serializer for this type
                serializer_cache[current_type] = current_serializer

                # If this is the type we're looking for, return it
                return current_serializer if type == current_type
              else
                # Can't traverse further, break out of this path
                break
              end
            else
              # Can't traverse further, break out of this path
              break
            end
          end
        end

        # Check our cache for any direct type matches
        serializer_cache[type]
      end

      def extract_attributes(serializer_class)
        attributes = []

        if serializer_class.respond_to?(:attributes_to_serialize)
          attributes = serializer_class.attributes_to_serialize.keys.map(&:to_s)
        end

        attributes
      end

      def extract_resource_type(serializer_class)
        if serializer_class.respond_to?(:record_type)
          serializer_class.record_type
        else
          # Fallback: derive from class name
          serializer_class.name.demodulize
                         .gsub(/Serializer$/, "")
                         .underscore
                         .pluralize
                         .to_sym
        end
      end
    end
  end
end
