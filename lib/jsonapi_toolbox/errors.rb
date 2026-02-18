# frozen_string_literal: true

module JsonapiToolbox
  module Errors
    class MissingAttributeError < StandardError
      attr_reader :pointer

      def initialize(name:)
        @pointer = "data/attributes/#{name}"
        super("Missing attribute: #{name}")
      end
    end

    class MissingRelationshipError < StandardError
      attr_reader :pointer

      def initialize(name:)
        @pointer = "data/relationships/#{name}"
        super("Missing relationship: #{name}")
      end
    end

    class InvalidIncludeError < StandardError
      attr_reader :invalid_includes, :allowed_includes

      def initialize(invalid_includes, allowed_includes)
        @invalid_includes = invalid_includes
        @allowed_includes = allowed_includes
        super("Invalid include parameters: #{invalid_includes.join(", ")}")
      end
    end

    class InvalidFieldsError < StandardError
      attr_reader :invalid_fields, :allowed_fields, :resource_type

      def initialize(invalid_fields, allowed_fields, resource_type)
        @invalid_fields = invalid_fields
        @allowed_fields = allowed_fields
        @resource_type = resource_type
        super("Invalid fields for #{resource_type}: #{invalid_fields.join(", ")}")
      end
    end

    class SerializerNotFoundError < StandardError
      def initialize(message)
        super(message)
      end
    end

    class ValidationError < StandardError
      attr_reader :validation_errors

      def initialize(validation_errors)
        @validation_errors = validation_errors
        error_messages = validation_errors.map(&:message)
        super("JSON:API validation failed: #{error_messages.join(", ")}")
      end
    end

    class UnpermittedAttributeError < StandardError
      attr_reader :attribute_names, :pointers

      def initialize(attribute_names)
        @attribute_names = attribute_names
        @pointers = attribute_names.map { |name| "/data/attributes/#{name}" }
        super("Unpermitted attribute(s): #{attribute_names.join(", ")}")
      end
    end

    class UnpermittedRelationshipError < StandardError
      attr_reader :relationship_names, :pointers

      def initialize(relationship_names)
        @relationship_names = relationship_names
        @pointers = relationship_names.map { |name| "/data/relationships/#{name}" }
        super("Unpermitted relationship(s): #{relationship_names.join(", ")}")
      end
    end
  end
end
