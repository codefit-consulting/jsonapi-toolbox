# frozen_string_literal: true

module JsonapiToolbox
  module Controller
    module SerializerDetection
      extend ActiveSupport::Concern

      delegate :serializer_class, to: :class

      class_methods do
        def serializer_class
          @detected_serializer ||= detect_serializer_class
        end

        private

        def detect_serializer_class
          # Extract the resource name from controller name
          # e.g., "Tour::Admin::Builder::API::V1::PackagesController" -> "Package"
          resource_name = name.demodulize.gsub(/Controller$/, "").singularize

          # Build the expected serializer class name using the same namespace
          # e.g., "Tour::Admin::Builder::API::V1::PackageSerializer"
          namespace_parts = name.deconstantize.split("::")
          serializer_name = "#{namespace_parts.join("::")}::#{resource_name}Serializer"

          begin
            serializer_name.constantize
          rescue NameError
            # Fallback: try without the last namespace part (remove version)
            if namespace_parts.length > 1
              fallback_namespace = namespace_parts[0..-2].join("::")
              fallback_name = "#{fallback_namespace}::#{resource_name}Serializer"

              begin
                fallback_name.constantize
              rescue NameError
                raise JsonapiToolbox::Errors::SerializerNotFoundError.new(
                  "Could not find serializer for #{name}. " \
                  "Tried: #{serializer_name}, #{fallback_name}"
                )
              end
            else
              raise JsonapiToolbox::Errors::SerializerNotFoundError.new(
                "Could not find serializer for #{name}. Tried: #{serializer_name}"
              )
            end
          end
        end
      end
    end
  end
end
