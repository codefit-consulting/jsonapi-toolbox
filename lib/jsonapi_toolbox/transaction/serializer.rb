# frozen_string_literal: true

module JsonapiToolbox
  module Transaction
    class Serializer
      include JsonapiToolbox::Serializer::Base

      set_type :transactions

      attributes :state, :timeout_seconds, :expires_at, :created_at
    end
  end
end
