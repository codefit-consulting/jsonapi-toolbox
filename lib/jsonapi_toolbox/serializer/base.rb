# frozen_string_literal: true

module JsonapiToolbox
  module Serializer
    module Base
      extend ActiveSupport::Concern

      included do
        include JSONAPI::Serializer
        # Guard: JSONAPI::Serializer::Instrumentation may not be present in all fork versions
        include JSONAPI::Serializer::Instrumentation if defined?(JSONAPI::Serializer::Instrumentation)
        include JsonapiToolbox::Serializer::DefaultValues
        include JsonapiToolbox::Serializer::IncludeHandling
        include JsonapiToolbox::Serializer::LazyRelationships
      end
    end
  end
end
