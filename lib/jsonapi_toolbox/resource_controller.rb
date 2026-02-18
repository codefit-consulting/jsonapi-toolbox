# frozen_string_literal: true

module JsonapiToolbox
  # A ready-made base controller for API-only applications.
  # Inherits from ActionController::API.
  #
  # Apps that need to inherit from their own ApplicationController (e.g. for auth,
  # middleware, or session handling) should compose the concerns directly instead:
  #
  #   class Core::ResourceController < ApplicationController
  #     include JsonapiToolbox::Controller::SerializerDetection
  #     include JsonapiToolbox::Controller::Validation
  #     include JsonapiToolbox::Controller::DataValidation
  #     include JsonapiToolbox::Controller::Rendering
  #
  #     rescue_from JsonapiToolbox::Errors::InvalidIncludeError,
  #                 JsonapiToolbox::Errors::InvalidFieldsError,
  #                 JsonapiToolbox::Errors::SerializerNotFoundError,
  #                 JsonapiToolbox::Errors::ValidationError,
  #                 JsonapiToolbox::Errors::UnpermittedAttributeError,
  #                 JsonapiToolbox::Errors::UnpermittedRelationshipError,
  #                 JSONAPI::Parser::InvalidDocument,
  #                 ActiveRecord::RecordNotFound,
  #                 with: :render_jsonapi_error
  #   end
  if defined?(ActionController::API)
    class ResourceController < ActionController::API
      include JsonapiToolbox::Controller::SerializerDetection
      include JsonapiToolbox::Controller::Validation
      include JsonapiToolbox::Controller::DataValidation
      include JsonapiToolbox::Controller::Rendering

      rescue_from JsonapiToolbox::Errors::InvalidIncludeError,
                  JsonapiToolbox::Errors::InvalidFieldsError,
                  JsonapiToolbox::Errors::SerializerNotFoundError,
                  JsonapiToolbox::Errors::ValidationError,
                  JsonapiToolbox::Errors::UnpermittedAttributeError,
                  JsonapiToolbox::Errors::UnpermittedRelationshipError,
                  JSONAPI::Parser::InvalidDocument,
                  ActiveRecord::RecordNotFound,
                  with: :render_jsonapi_error
    end
  end
end
