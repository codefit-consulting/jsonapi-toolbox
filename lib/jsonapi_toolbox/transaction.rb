# frozen_string_literal: true

require "singleton"
require "json_api_client"

require "jsonapi_toolbox/transaction/errors"
require "jsonapi_toolbox/transaction/held_transaction"
require "jsonapi_toolbox/transaction/manager"
require "jsonapi_toolbox/transaction/serializer"
require "jsonapi_toolbox/controller/transaction_aware"
require "jsonapi_toolbox/controller/transactions_actions"
require "jsonapi_toolbox/client/errors"
require "jsonapi_toolbox/client/service_token_middleware"
require "jsonapi_toolbox/client/transaction_id_middleware"
require "jsonapi_toolbox/client/transaction_reaped_middleware"
require "jsonapi_toolbox/client/request_serializer_middleware"
require "jsonapi_toolbox/client/lazy_transaction"
require "jsonapi_toolbox/client/base"
require "jsonapi_toolbox/client/transaction"

module JsonapiToolbox
  module Transaction
    class Configuration
      # --- Receiver policy (used when this app *hosts* a transaction) ---
      #
      # lease_ttl_default   lease granted when the client requests none — reap if
      #                     no message (heartbeat or real op) for this long.
      # lease_ttl_min/max   clamp range for a client-requested lease.
      # hard_cap_ttl_default absolute max lifetime (seconds from creation)
      #                     regardless of heartbeats — the runaway sanity check.
      #                     **nil disables it entirely.** Your app should never
      #                     need — or ask — to hold a single remote transaction
      #                     open anywhere near this long; if it trips, something
      #                     is genuinely wrong (a runaway that keeps
      #                     heartbeating), not merely slow.
      # hard_cap_ttl_max    clamp for a client-requested hard_cap_ttl (nil = no ceiling).
      # reaper_scan_interval how often the reaper scans (reap-latency granularity).
      #
      # --- Client policy (used when this app *initiates* a transaction) ---
      #
      # heartbeat_divisor      heartbeats per lease window → tolerate divisor-1
      #                        misses; interval = granted_ttl / divisor.
      # heartbeat_min_interval floor, so a small lease can't cause a heartbeat storm.
      # requested_lease_ttl    optional lease request (nil → server default);
      #                        also settable per-transaction via within_transaction.
      # requested_hard_cap_ttl optional hard_cap_ttl request (nil → server default);
      #                        also settable per-transaction via within_transaction.
      #
      # The gem never reads ENV itself — each app overrides whichever value it
      # wants via `configure`, from ENV or literals (the app author's choice).
      attr_accessor :max_concurrent,
                    :lease_ttl_default, :lease_ttl_min, :lease_ttl_max,
                    :hard_cap_ttl_default, :hard_cap_ttl_max,
                    :reaper_scan_interval,
                    :heartbeat_divisor, :heartbeat_min_interval,
                    :requested_lease_ttl, :requested_hard_cap_ttl

      def initialize
        @max_concurrent = 10

        @lease_ttl_default = 30
        @lease_ttl_min = 10
        @lease_ttl_max = 120
        @hard_cap_ttl_default = 3600 # 1h; nil disables
        @hard_cap_ttl_max = 3600     # nil = no ceiling on a requested hard_cap_ttl
        @reaper_scan_interval = 5

        @heartbeat_divisor = 3
        @heartbeat_min_interval = 2
        @requested_lease_ttl = nil
        @requested_hard_cap_ttl = nil
      end
    end

    class << self
      attr_writer :logger

      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield(configuration)
      end

      def logger
        @logger
      end

      def reset_configuration!
        @configuration = Configuration.new
      end
    end
  end
end
