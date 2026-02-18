# frozen_string_literal: true

module JsonapiToolbox
  module Controller
    module Rendering
      extend ActiveSupport::Concern

      private

      def render_jsonapi(resource, options = {})
        # Extract serializer from options or use auto-detected one
        serializer_class = options.delete(:serializer) || self.serializer_class

        # Build serializer options from validated parameters
        serializer_options = build_serializer_options(options)

        # Render using the jsonapi-serializer
        serialized_data = serializer_class.new(resource, serializer_options)

        render json: serialized_data.serializable_hash, status: options[:status] || :ok
      end

      def render_jsonapi_error(error)
        case error
        when JsonapiToolbox::Errors::InvalidIncludeError
          render json: {
            errors: [ {
              status: "400",
              title: "Invalid Include Parameter",
              detail: "\nInvalid include parameters:\n\n#{error.invalid_includes.join("\n")}" \
                     "\n\nAllowed include parameters:\n\n#{error.allowed_includes.join("\n")}",
              source: { parameter: "include" }
            } ]
          }, status: :bad_request
        when JsonapiToolbox::Errors::InvalidFieldsError
          render json: {
            errors: [ {
              status: "400",
              title: "Invalid Fields Parameter",
              detail: "Invalid field(s) for type '#{error.resource_type}': #{error.invalid_fields.join(", ")}. " \
                     "Allowed fields: #{error.allowed_fields.join(", ")}",
              source: { parameter: "fields[#{error.resource_type}]" }
            } ]
          }, status: :bad_request
        when JsonapiToolbox::Errors::ValidationError
          errors = []
          error.validation_errors.each do |validation_error|
            case validation_error
            when JsonapiToolbox::Errors::UnpermittedAttributeError
              validation_error.attribute_names.zip(validation_error.pointers).each do |name, pointer|
                errors << {
                  status: "400",
                  title: "Unpermitted Attribute",
                  detail: "Attribute '#{name}' is not permitted",
                  source: { pointer: pointer }
                }
              end
            when JsonapiToolbox::Errors::UnpermittedRelationshipError
              validation_error.relationship_names.zip(validation_error.pointers).each do |name, pointer|
                errors << {
                  status: "400",
                  title: "Unpermitted Relationship",
                  detail: "Relationship '#{name}' is not permitted",
                  source: { pointer: pointer }
                }
              end
            else
              errors << {
                status: "400",
                title: "JSON:API Validation Error",
                detail: validation_error.message,
                source: { pointer: validation_error.respond_to?(:pointer) ? validation_error.pointer : nil }.compact
              }
            end
          end
          render json: { errors: errors }, status: :bad_request
        when JsonapiToolbox::Errors::UnpermittedAttributeError
          errors = error.attribute_names.zip(error.pointers).map do |name, pointer|
            {
              status: "400",
              title: "Unpermitted Attribute",
              detail: "Attribute '#{name}' is not permitted",
              source: { pointer: pointer }
            }
          end
          render json: { errors: errors }, status: :bad_request
        when JsonapiToolbox::Errors::UnpermittedRelationshipError
          errors = error.relationship_names.zip(error.pointers).map do |name, pointer|
            {
              status: "400",
              title: "Unpermitted Relationship",
              detail: "Relationship '#{name}' is not permitted",
              source: { pointer: pointer }
            }
          end
          render json: { errors: errors }, status: :bad_request
        when JsonapiToolbox::Errors::SerializerNotFoundError
          render json: {
            errors: [ {
              status: "500",
              title: "Serializer Configuration Error",
              detail: error.message
            } ]
          }, status: :internal_server_error
        when JSONAPI::Parser::InvalidDocument
          render json: {
            errors: [ {
              status: "400",
              title: "Invalid JSON:API Document",
              detail: error.message
            } ]
          }, status: :bad_request
        when ActiveRecord::RecordNotFound
          if error.message.include?("::")
            if [ error.model, error.primary_key, error.id ].all?(&:present?)
              detail = "Couldn't find #{error.model.demodulize} with '#{error.primary_key}'=#{error.id}"
            else
              detail = error.message.sub(/(\w+::)+/, "")
            end
          else
            detail = error.message
          end

          render json: {
            errors: [ {
              status: "404",
              title: "Record Not Found",
              detail: detail
            } ]
          }, status: :not_found
        else
          # Handle optional ActiveInteraction errors if the gem is loaded
          if defined?(ActiveInteraction) && error.is_a?(ActiveInteraction::InvalidInteractionError)
            render json: {
              errors: [ {
                status: "422",
                title: "Validation Error",
                detail: error.message
              } ]
            }, status: :unprocessable_entity
          else
            # Fallback for other errors
            render json: {
              errors: [ {
                status: "500",
                title: "Internal Server Error",
                detail: error.message
              } ]
            }, status: :internal_server_error
          end
        end
      end

      def build_serializer_options(additional_options = {})
        options = {}

        # Add include parameter if validated
        options[:include] = @validated_includes if @validated_includes

        # Add fields parameter if validated
        options[:fields] = @validated_fields if @validated_fields

        # Merge any additional options passed to render_jsonapi
        options.merge!(additional_options)

        options
      end
    end
  end
end
