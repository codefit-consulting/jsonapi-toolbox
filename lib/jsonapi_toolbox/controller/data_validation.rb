# frozen_string_literal: true

module JsonapiToolbox
  module Controller
    module DataValidation
      extend ActiveSupport::Concern

      def extract_and_validate_jsonapi_data(permitted_attributes: [], required_attributes: [], permitted_relationships: [], required_relationships: [])
        # NOTE: We have already validated the JSON:API document structure
        # before this method is invoked, so we know we have:
        #
        # - valid data.attributes
        # - valid data.relationships with ids present
        #
        # So we don't need to check these things here as well. This method is
        # concerned with WHAT the attributes and relationships are, NOT whether
        # they are well-formed.

        # Extract data from the JSON:API document
        data = params[:data].to_unsafe_h.with_indifferent_access
        attributes_data = data[:attributes] || {}
        relationships_data = data[:relationships] || {}

        # Collect all validation errors
        errors = []

        # Extract permitted attributes
        permitted_attrs = attributes_data.slice(*permitted_attributes)

        # Validate required attributes
        required_attributes.each do |attr_name|
          if attributes_data.key?(attr_name)
            permitted_attrs[attr_name] = attributes_data[attr_name]
          else
            errors << JsonapiToolbox::Errors::MissingAttributeError.new(name: attr_name)
          end
        end

        # Validate required relationships
        required_relationships.each do |rel_name|
          rel_data = relationships_data[rel_name]
          if rel_data.nil?
            errors << JsonapiToolbox::Errors::MissingRelationshipError.new(name: rel_name)
          end
        end

        # Check for unpermitted attributes
        all_allowed_attributes = (permitted_attributes + required_attributes).uniq
        unpermitted_attributes = attributes_data.keys - all_allowed_attributes.map(&:to_s)
        if unpermitted_attributes.any?
          errors << JsonapiToolbox::Errors::UnpermittedAttributeError.new(unpermitted_attributes)
        end

        # Check for unpermitted relationships
        all_allowed_relationships = (permitted_relationships + required_relationships).uniq
        unpermitted_relationships = relationships_data.keys - all_allowed_relationships.map(&:to_s)
        if unpermitted_relationships.any?
          errors << JsonapiToolbox::Errors::UnpermittedRelationshipError.new(unpermitted_relationships)
        end

        # If we have validation errors, raise them all at once
        if errors.any?
          raise JsonapiToolbox::Errors::ValidationError.new(errors)
        end

        # Extract relationship IDs and merge them into the attributes
        # This allows the controller to use them as foreign keys
        # Only process allowed relationships
        all_allowed_relationships.each do |rel_name|
          rel_data = relationships_data[rel_name]
          next unless rel_data

          if rel_data[:data].is_a?(Hash)
            # belongs_to relationship - single ID
            permitted_attrs["#{rel_name}_id"] = rel_data[:data][:id]
          elsif rel_data[:data].is_a?(Array)
            # has_many relationship - array of IDs
            permitted_attrs["#{rel_name.to_s.singularize}_ids"] = rel_data[:data].map { |item| item[:id] }
          end
        end

        permitted_attrs
      end

      # Alias for backward compatibility
      alias_method :validate_data, :extract_and_validate_jsonapi_data
    end
  end
end
