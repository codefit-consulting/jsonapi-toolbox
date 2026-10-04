# frozen_string_literal: true

module JsonapiToolbox
  module Serializer
    # Loads everything that serializing some records will read, one level of
    # the include tree at a time:
    #
    # 1. On the records at a level, ActiveRecord preloads three things: the
    #    associations their serializer's attributes declare, the extras that
    #    the relationship which reached them declares, and the association
    #    (or chain) behind each relationship requested below them.
    # 2. For each requested relationship whose records need anything, the gem
    #    asks the relationship for its records and repeats step 1 on them.
    #
    # Records fetched in step 2 are kept in a FetchStore that travels to the
    # serializer in params, so serializing reads the very same objects. The
    # plan in docs/plans/include-handling-redesign.md walks through the SQL.
    module Preloader
      # The key in serializer params under which the FetchStore travels.
      STORE_PARAM = :jsonapi_toolbox_fetched_records

      # Relationship records fetched during one render, keyed by relationship
      # and record identity.
      class FetchStore
        def initialize
          @records = {}.compare_by_identity
        end

        def fetch(relationship, record)
          by_record = (@records[relationship] ||= {}.compare_by_identity)
          return by_record[record] if by_record.key?(record)

          by_record[record] = yield
        end
      end

      # Prepended to FastJsonapi::Relationship. While params carry a FetchStore,
      # a relationship returns the records it returned the first time it was
      # asked during this render. Without a store it behaves as before.
      module StoreLookup
        def fetch_associated_object(record, params)
          store = params.is_a?(Hash) ? params[STORE_PARAM] : nil
          return super unless store

          store.fetch(self, record) { super }
        end

        # For a relationship with a block, jsonapi-serializer computes linkage
        # ids by calling the block again. This reads the stored records
        # instead, and otherwise mirrors jsonapi-serializer 2.2's fetch_id.
        def fetch_id(record, params)
          store = params.is_a?(Hash) ? params[STORE_PARAM] : nil
          return super unless store && object_block

          object = fetch_associated_object(record, params)
          return object.map { |item| item.public_send(id_method_name) } if object.respond_to?(:map)

          object.try(id_method_name)
        end
      end

      class << self
        # Checks `tree` against `serializer`, then preloads onto `resource` (a
        # record, an array or a relation) everything that serializing it will
        # read. Returns `params` with a FetchStore added, to pass to the
        # serializer. Pass the serializer's is_collection option too, if any.
        def call(serializer, resource, tree, params: {}, is_collection: nil)
          IncludeTree.validate!(serializer, tree)

          params = (params || {}).merge(STORE_PARAM => FetchStore.new)
          load_level(serializer, primary_records(serializer, resource, is_collection), tree, params, {})
          params
        end

        # Runs ActiveRecord's preloader on records that are already loaded. That
        # class is internal Rails API (marked :nodoc:), and its interface
        # changed in Rails 7.0, so this is the one place the gem calls it.
        def preload_associations(records, associations)
          return if records.empty? || associations.empty?

          if ::ActiveRecord::VERSION::MAJOR >= 7
            ::ActiveRecord::Associations::Preloader.new(records: records, associations: associations).call
          else
            ::ActiveRecord::Associations::Preloader.new.preload(records, associations)
          end
        end

        private

        def load_level(serializer, records, tree, params, extra_preloads)
          records = records.compact.uniq(&:__id__)
          return if records.empty?

          preload_active_records(serializer, records, tree, extra_preloads)

          tree.each do |name, subtree|
            relationship = IncludeHandling.relationships_of(serializer)[name]
            target = IncludeHandling.static_serializer_of(relationship)
            next unless target

            preloads = IncludeHandling.relationship_preloads(serializer, name)
            next if subtree.empty? && preloads.empty? && IncludeHandling.attribute_preloads(target).empty?

            # Array() is how jsonapi-serializer reads included records too.
            related = records.flat_map do |record|
              next [] unless relationship.include_relationship?(record, params)

              Array(relationship.fetch_associated_object(record, params))
            end
            load_level(target, related, subtree, params, preloads)
          end
        end

        # Records of different classes can share a level, so each class is
        # checked and preloaded on its own.
        def preload_active_records(serializer, records, tree, extra_preloads)
          records.select { |record| active_record?(record) }.group_by(&:class).each do |model, group|
            associations = IncludeHandling.attribute_preloads(serializer).deep_merge(extra_preloads)

            tree.each_key do |name|
              relationship = IncludeHandling.relationships_of(serializer)[name]
              path = IncludeHandling.association_path(serializer, name, relationship)
              next if path == false

              check_association_path!(serializer, name, model, path)
              associations = associations.deep_merge(nest(path))
            end

            preload_associations(group, associations)
          end
        end

        # Raises when a step of the chain is not an association, instead of
        # letting the relationship fall back to one query per record.
        def check_association_path!(serializer, name, model, path)
          current = model
          path.each do |step|
            reflection = current.reflect_on_association(step)
            raise missing_association(serializer, name, model, current, step) unless reflection
            return if reflection.respond_to?(:polymorphic?) && reflection.polymorphic?

            current = reflection.klass
          end
        end

        def missing_association(serializer, name, model, current, step)
          problem =
            if IncludeHandling.association_declared?(serializer, name)
              "#{serializer.name}##{name}: association: names :#{step}, " \
              "but #{current.name} has no association with that name."
            else
              "#{serializer.name}##{name}: #{model.name} has no association named :#{step}. " \
              "Declare association: false if #{name} is a plain method, " \
              "or name the association it loads through with association:."
            end
          JsonapiToolbox::Errors::IncludeDeclarationError.new([ problem ])
        end

        # [ :property, :room_types ] becomes { property: { room_types: {} } }.
        def nest(path)
          path.reverse.reduce({}) { |nested, step| { step => nested } }
        end

        # The records the serializer will treat as primary data, decided by the
        # serializer's own collection test so that both always agree. That test
        # needs an Enumerable, which a Rails 4.2 relation is not.
        def primary_records(serializer, resource, is_collection)
          return [] if resource.nil?

          collection =
            if serializer.respond_to?(:is_collection?)
              serializer.is_collection?(resource, is_collection)
            else
              resource.is_a?(Enumerable) && !resource.respond_to?(:each_pair)
            end
          collection ? resource.to_a : [ resource ]
        end

        def active_record?(record)
          defined?(::ActiveRecord::Base) && record.is_a?(::ActiveRecord::Base)
        end
      end
    end
  end
end

FastJsonapi::Relationship.prepend(JsonapiToolbox::Serializer::Preloader::StoreLookup)
