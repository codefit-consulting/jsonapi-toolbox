# frozen_string_literal: true

require "spec_helper"
require "jsonapi_toolbox/transaction"

RSpec.describe JsonapiToolbox::Transaction do
  after { described_class.reset_configuration! }

  describe ".configure" do
    it "yields a configuration object" do
      described_class.configure do |config|
        config.max_concurrent = 5
        config.lease_ttl_default = 15
        config.lease_ttl_min = 5
        config.lease_ttl_max = 45
        config.hard_cap_ttl_default = 7200
        config.hard_cap_ttl_max = nil
        config.reaper_scan_interval = 3
        config.heartbeat_divisor = 4
        config.heartbeat_min_interval = 1
        config.requested_lease_ttl = 20
        config.requested_hard_cap_ttl = 300
      end

      config = described_class.configuration
      expect(config.max_concurrent).to eq(5)
      expect(config.lease_ttl_default).to eq(15)
      expect(config.lease_ttl_min).to eq(5)
      expect(config.lease_ttl_max).to eq(45)
      expect(config.hard_cap_ttl_default).to eq(7200)
      expect(config.hard_cap_ttl_max).to be_nil
      expect(config.reaper_scan_interval).to eq(3)
      expect(config.heartbeat_divisor).to eq(4)
      expect(config.heartbeat_min_interval).to eq(1)
      expect(config.requested_lease_ttl).to eq(20)
      expect(config.requested_hard_cap_ttl).to eq(300)
    end
  end

  describe ".configuration" do
    it "returns defaults" do
      config = described_class.configuration
      expect(config.max_concurrent).to eq(10)
      expect(config.lease_ttl_default).to eq(30)
      expect(config.lease_ttl_min).to eq(10)
      expect(config.lease_ttl_max).to eq(120)
      expect(config.hard_cap_ttl_default).to eq(3600)
      expect(config.hard_cap_ttl_max).to eq(3600)
      expect(config.reaper_scan_interval).to eq(5)
      expect(config.heartbeat_divisor).to eq(3)
      expect(config.heartbeat_min_interval).to eq(2)
      expect(config.requested_lease_ttl).to be_nil
      expect(config.requested_hard_cap_ttl).to be_nil
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
