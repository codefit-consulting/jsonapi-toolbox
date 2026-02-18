# frozen_string_literal: true

module JsonapiToolbox
  class Railtie < Rails::Railtie
    initializer "jsonapi_toolbox.mime_type" do
      Mime::Type.register "application/vnd.api+json", :jsonapi unless Mime::Type.lookup_by_extension(:jsonapi)

      json_parser = ->(body) { JSON.parse(body) }

      if ActionDispatch::Request.respond_to?(:parameter_parsers)
        # Rails 5+
        ActionDispatch::Request.parameter_parsers[:jsonapi] = json_parser
      else
        # Rails 4.x
        ActionDispatch::ParamsParser::DEFAULT_PARSERS[Mime::Type.lookup("application/vnd.api+json")] = json_parser
      end
    end

    initializer "jsonapi_toolbox.action_controller" do
      ActiveSupport.on_load(:action_controller) do
        # Nothing auto-included; consuming apps inherit from JsonapiToolbox::ResourceController
        # and include JsonapiToolbox::Serializer::Base in their serializers.
      end
    end
  end
end
