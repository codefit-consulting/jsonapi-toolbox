# frozen_string_literal: true

module JsonapiToolbox
  module Serializer
    class Configuration
      # max_include_depth  the most segments one ?include= path may have, such
      #                    as 3 for "room_types.rates.currency". A path may run
      #                    through any relationship a serializer allows, so
      #                    this limit is also what stops a client following a
      #                    cycle of relationships forever.
      attr_reader :max_include_depth

      def initialize
        @max_include_depth = 8
      end

      def max_include_depth=(depth)
        unless depth.is_a?(Integer) && depth.positive?
          raise ArgumentError, "max_include_depth must be a positive integer, got #{depth.inspect}"
        end

        @max_include_depth = depth
      end
    end

    class << self
      def configuration
        @configuration ||= Configuration.new
      end

      def configure
        yield(configuration)
      end

      def reset_configuration!
        @configuration = Configuration.new
      end
    end
  end
end
