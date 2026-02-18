# frozen_string_literal: true

require "jsonapi/parser"
require "jsonapi/serializer"

require "jsonapi_toolbox/version"
require "jsonapi_toolbox/errors"
require "jsonapi_toolbox/serializer/default_values"
require "jsonapi_toolbox/serializer/include_handling"
require "jsonapi_toolbox/serializer/lazy_relationships"
require "jsonapi_toolbox/serializer/base"
require "jsonapi_toolbox/controller/serializer_detection"
require "jsonapi_toolbox/controller/validation"
require "jsonapi_toolbox/controller/data_validation"
require "jsonapi_toolbox/controller/rendering"
require "jsonapi_toolbox/resource_controller"

if defined?(Rails)
  require "jsonapi_toolbox/railtie"

  if defined?(JSONAPI::Serializer::Instrumentation)
    require "jsonapi/serializer/instrumentation"
  end
end

module JsonapiToolbox
end
