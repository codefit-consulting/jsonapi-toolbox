# frozen_string_literal: true

module JsonapiToolbox
  module Transaction
    class Serializer
      include JsonapiToolbox::Serializer::Base

      set_type :transactions

      # lease_ttl + hard_cap_ttl are the negotiated grant the client reads back
      # to set its heartbeat cadence (create-time negotiation).
      attributes :state, :lease_ttl, :hard_cap_ttl, :expires_at, :created_at
    end
  end
end
