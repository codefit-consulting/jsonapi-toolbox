# frozen_string_literal: true

module JsonapiToolbox
  module Serializer
    module DefaultValues
      extend ActiveSupport::Concern

      included do
        set_type auto_detect_type
      end

      class_methods do
        private

        def auto_detect_type
          name.demodulize
              .gsub(/Serializer$/, "")
              .underscore
              .pluralize
              .to_sym
        end
      end
    end
  end
end
