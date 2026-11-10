# frozen_string_literal: true

module JsonapiToolbox
  module Client
    # JSON:API requires every resource id to be a string. json_api_client
    # copies whatever Ruby holds straight into the request body, so a
    # reference built as `Departure.new(id: 77)` is sent as the JSON number
    # 77. This module coerces ids to strings while the body is being built
    # and leaves the stored attribute alone, so a caller that reads
    # `record.id` back still gets the Integer it assigned.
    #
    # Three methods on JsonApiClient::Resource feed a request body, and all
    # three are covered here:
    #
    #   as_json_api
    #     the whole body for POST and PATCH, carrying the resource's own id
    #     and its relationships.
    #   as_relation
    #     this resource seen as some other resource's relationship.
    #   relationships_for_serialization
    #     the relationships hash. Assigning a resource, an array of
    #     resources, or a raw {"data" => ...} hash all end up here, which is
    #     why the walk below normalises the hash rather than trusting
    #     as_relation to have run.
    #
    # A to-one relationship sent as nil stays null, because "data": null is
    # how a relationship is cleared. An empty to-many array stays empty.
    module StringIds
      def as_json_api(*)
        StringIds.stringify_resource_id(super, self.class.primary_key)
      end

      def as_relation
        StringIds.stringify_resource_id(super, self.class.primary_key)
      end

      protected

      def relationships_for_serialization
        StringIds.stringify_relationships(super)
      end

      class << self
        # Copies `hash` with its id value stringified. A nil id, an id that
        # is already a String, and a hash with no id at all (a create, where
        # the server assigns the id) are all returned untouched.
        def stringify_resource_id(hash, primary_key = :id)
          return hash unless hash.is_a?(Hash)

          key = id_key(hash, primary_key)
          return hash if key.nil?

          id = hash[key]
          return hash if id.nil? || id.is_a?(String)

          hash.dup.tap { |copy| copy[key] = id.to_s }
        end

        # Walks {relationship_name => {"data" => linkage}} and stringifies
        # the id of every linkage it finds, to-one and to-many alike.
        def stringify_relationships(relationships)
          return relationships unless relationships.is_a?(Hash)

          relationships.each_with_object(relationships.dup) do |(name, relationship), result|
            next unless relationship.is_a?(Hash)

            data_key = first_key(relationship, :data)
            next if data_key.nil?

            data = relationship[data_key]
            stringified = stringify_linkage(data)
            next if stringified.equal?(data)

            result[name] = relationship.dup.tap { |copy| copy[data_key] = stringified }
          end
        end

        private

        # A relationship's "data" is one linkage hash, an array of them, or
        # nil. Anything else, nil included, passes straight through.
        def stringify_linkage(data)
          case data
          when Array
            coerced = data.map { |member| stringify_resource_id(member) }
            coerced.zip(data).all? { |after, before| after.equal?(before) } ? data : coerced
          when Hash
            stringify_resource_id(data)
          else
            data
          end
        end

        # The primary key may be held as a String or a Symbol depending on
        # how the resource class declared it, and a plain Hash (unlike the
        # HashWithIndifferentAccess json_api_client normally hands back) only
        # answers to the form it was written with.
        def id_key(hash, primary_key)
          first_key(hash, primary_key || :id)
        end

        def first_key(hash, name)
          return name if hash.key?(name)

          [ name.to_s, name.to_s.to_sym ].find { |candidate| hash.key?(candidate) }
        end
      end
    end
  end
end
