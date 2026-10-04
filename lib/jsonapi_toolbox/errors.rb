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

    # A requested ?include= path that cannot be served, rendered as a 400. The
    # message names the path up to the failing segment and says what could be
    # included there instead.
    class InvalidIncludeError < StandardError
      attr_reader :path, :segment, :includable

      def initialize(message, path:, segment: nil, includable: [])
        @path = path
        @segment = segment
        @includable = includable
        super(message)
      end
    end

    # A serializer's include declarations cannot work, for example because a
    # relationship's serializer class does not exist or its model lacks the
    # association it loads through. Raised by verify_includes! with every
    # problem found, and while serving a request with the one it hit. Apps
    # leave it unrescued, so it surfaces as a 500.
    class IncludeDeclarationError < StandardError
      attr_reader :problems

      def initialize(problems)
        @problems = problems
        super("Invalid include declarations:\n#{problems.map { |problem| "  - #{problem}" }.join("\n")}")
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
