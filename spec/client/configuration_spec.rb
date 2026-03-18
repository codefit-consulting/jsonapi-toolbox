# frozen_string_literal: true

require "spec_helper"
require "jsonapi_toolbox/client"

RSpec.describe JsonapiToolbox::Client do
  after { described_class.reset_configuration! }

  describe ".configuration" do
    it "returns a Configuration instance" do
      expect(described_class.configuration).to be_a(described_class::Configuration)
    end

    it "defaults persistent_connections to true" do
      expect(described_class.configuration.persistent_connections).to be true
    end
  end

  describe ".configure" do
    it "yields the configuration" do
      described_class.configure do |config|
        config.persistent_connections = false
      end

      expect(described_class.configuration.persistent_connections).to be false
    end
  end

  describe ".reset_configuration!" do
    it "restores defaults" do
      described_class.configure { |c| c.persistent_connections = false }
      described_class.reset_configuration!

      expect(described_class.configuration.persistent_connections).to be true
    end
  end
end

RSpec.describe JsonapiToolbox::Client::Base do
  after { JsonapiToolbox::Client.reset_configuration! }

  let(:resource_class) do
    Class.new(described_class) do
      self.site = "https://example.com/api/"
    end
  end

  describe "persistent connection adapter" do
    it "uses net_http_persistent adapter when persistent_connections is true" do
      connection = resource_class.connection
      adapter_name = connection.faraday.builder.adapter.name
      expect(adapter_name).to include("NetHttpPersistent")
    end

    it "uses the default adapter when persistent_connections is false" do
      JsonapiToolbox::Client.configure { |c| c.persistent_connections = false }

      fresh_class = Class.new(described_class) do
        self.site = "https://example.com/api/"
      end

      connection = fresh_class.connection
      adapter_name = connection.faraday.builder.adapter.name
      expect(adapter_name).not_to include("NetHttpPersistent")
    end
  end
end
