# frozen_string_literal: true

require "spec_helper"
require "jsonapi_toolbox/transaction"

RSpec.describe JsonapiToolbox::Transaction do
  after { described_class.reset_configuration! }

  describe ".configure" do
    it "yields a configuration object" do
      described_class.configure do |config|
        config.max_concurrent = 5
        config.default_timeout = 15
        config.max_timeout = 45
        config.reaper_interval = 3
      end

      config = described_class.configuration
      expect(config.max_concurrent).to eq(5)
      expect(config.default_timeout).to eq(15)
      expect(config.max_timeout).to eq(45)
      expect(config.reaper_interval).to eq(3)
    end
  end

  describe ".configuration" do
    it "returns defaults" do
      config = described_class.configuration
      expect(config.max_concurrent).to eq(10)
      expect(config.default_timeout).to eq(30)
      expect(config.max_timeout).to eq(60)
      expect(config.reaper_interval).to eq(5)
    end
  end

  describe ".logger" do
    it "can be set and retrieved" do
      logger = double("logger")
      described_class.logger = logger
      expect(described_class.logger).to eq(logger)
      described_class.logger = nil
    end
  end
end
