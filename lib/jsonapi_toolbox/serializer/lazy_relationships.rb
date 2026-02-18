# frozen_string_literal: true

module JsonapiToolbox
  module Serializer
    module LazyRelationships
      extend ActiveSupport::Concern

      class_methods do
        def lazy_has_many(name, **opts, &block)
          has_many(name, lazy_load_data: true, **opts, &block)
        end

        def lazy_has_one(name, **opts, &block)
          has_one(name, lazy_load_data: true, **opts, &block)
        end

        def lazy_belongs_to(name, **opts, &block)
          belongs_to(name, lazy_load_data: true, **opts, &block)
        end
      end
    end
  end
end
