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

      # Walks the requested include paths through the serializers before the
      # action runs, so a bad path gets a 400 before anything is changed. The
      # tree is kept for render_jsonapi, which preloads along it.
      def validate_includes
        return unless params[:include]

        tree = JsonapiToolbox::Serializer::IncludeTree.parse(params[:include])
        JsonapiToolbox::Serializer::IncludeTree.validate!(serializer_class, tree)

        @validated_include_tree = tree
        @validated_includes = JsonapiToolbox::Serializer::IncludeTree.paths(params[:include])
      end

      # Checks each requested fieldset against the serializer for its type. A
      # type is known when it is the primary type or the request includes it;
      # fieldsets for other types are ignored, since nothing of that type is
      # in the response.
      def validate_sparse_fieldsets
        return unless params[:fields] && params[:fields].is_a?(ActionController::Parameters)

        serializers = JsonapiToolbox::Serializer::IncludeTree.serializers_by_type(
          serializer_class, @validated_include_tree || {}
        )

        @validated_fields = {}

        params[:fields].each do |type, field_list|
          requested_fields = field_list.to_s.split(",").map(&:strip).map(&:to_sym)

          type_serializer = serializers[type.to_s]
          next unless type_serializer

          # Attributes only; relationships are not accepted as fields
          allowed_fields = extract_attributes(type_serializer)

          invalid_fields = requested_fields.map(&:to_s) - allowed_fields.map(&:to_s)
          if invalid_fields.any?
            raise JsonapiToolbox::Errors::InvalidFieldsError.new(invalid_fields, allowed_fields, type)
          end

          @validated_fields[type.to_sym] = requested_fields
        end
      end

      def extract_attributes(serializer_class)
        attributes = []

        if serializer_class.respond_to?(:attributes_to_serialize)
          attributes = serializer_class.attributes_to_serialize.keys.map(&:to_s)
        end

        attributes
      end
    end
  end
end
