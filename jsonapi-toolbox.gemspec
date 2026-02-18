# frozen_string_literal: true

require_relative "lib/jsonapi_toolbox/version"

Gem::Specification.new do |spec|
  spec.name    = "jsonapi-toolbox"
  spec.version = JsonapiToolbox::VERSION
  spec.authors = [ "jmchambers" ]
  spec.summary = "JSON:API serializer and controller tooling built on jsonapi-serializer"

  spec.required_ruby_version = ">= 2.6"

  spec.files = Dir["lib/**/*.rb"]

  spec.add_dependency "activesupport", ">= 4.2"
  spec.add_dependency "actionpack", ">= 4.2"
  spec.add_dependency "jsonapi-parser", "~> 0.1.1"
  # Consuming apps should override this in their Gemfile to the jmchambers fork:
  #   gem "jsonapi-serializer", git: "https://github.com/jmchambers/jsonapi-serializer.git", branch: "master"
  spec.add_dependency "jsonapi-serializer", "~> 2.2"
end
