# frozen_string_literal: true

module JsonapiToolbox
  module Serializer
    # Checks the include declarations of every serializer given and raises one
    # Errors::IncludeDeclarationError listing all the problems, so an app can
    # verify all of its serializers from a single spec. Returns true otherwise.
    # Accepts serializer classes, or arrays, sets or other enumerables of them,
    # and raises ArgumentError for anything else, or for nothing at all, so a
    # spec cannot pass by checking nothing.
    def self.verify_includes!(*serializers)
      serializers = serializers.flatten.flat_map { |item| item.is_a?(Enumerable) ? item.to_a.flatten : [ item ] }
      raise ArgumentError, "verify_includes! was given no serializers" if serializers.empty?

      others = serializers.reject { |item| item.is_a?(Module) && item.respond_to?(:_include_allowlist) }
      if others.any?
        raise ArgumentError,
              "verify_includes! expects serializer classes that include JsonapiToolbox::Serializer::Base, " \
              "got #{others.map(&:inspect).join(", ")}"
      end

      problems = serializers.flat_map { |serializer| IncludeHandling.declaration_problems(serializer) }
      raise JsonapiToolbox::Errors::IncludeDeclarationError.new(problems) if problems.any?

      true
    end

    # Declares which relationships a client may include, how each relationship
    # loads, and which associations each attribute reads. IncludeTree checks
    # requests against these declarations, and Preloader loads what they need.
    #
    # Every serializer includes this module, so it defines no constants of its
    # own: Ruby looks constants up through a class's ancestors before Object,
    # so a constant here would hide an app's constant of the same name inside
    # every serializer.
    module IncludeHandling
      extend ActiveSupport::Concern

      class << self
        def relationships_of(serializer)
          (serializer.respond_to?(:relationships_to_serialize) && serializer.relationships_to_serialize) || {}
        end

        # The serializer class for a relationship's records, or nil when
        # jsonapi-serializer chooses one per record (polymorphic relationships,
        # blocks without a serializer: option). Raises NameError when the class
        # it names or infers does not exist.
        def static_serializer_of(relationship)
          relationship.respond_to?(:static_serializer) ? relationship.static_serializer : nil
        end

        # Like static_serializer_of, but a class that cannot be resolved is a
        # declaration problem in the serializer, reported as such.
        def static_serializer!(serializer, name, relationship)
          static_serializer_of(relationship)
        rescue NameError => e
          raise JsonapiToolbox::Errors::IncludeDeclarationError.new(
            [ "#{serializer.name}: relationship :#{name} cannot resolve its serializer: #{describe_error(e)}" ]
          )
        end

        # The relationships a client may include from this serializer, in
        # declaration order. Without allow_includes, that is all of them.
        def includable_names(serializer)
          names = relationships_of(serializer).keys
          allowlist = serializer.respond_to?(:_include_allowlist) ? serializer._include_allowlist : nil
          allowlist ? names & allowlist : names
        end

        def includable?(serializer, name)
          includable_names(serializer).include?(name)
        end

        # The chain of associations a relationship loads through, such as
        # [:productable, :room_types], or false when it is fetched through the
        # serializer instead. By default it is the association jsonapi-serializer
        # reads, which is the relationship's name unless it sets object_method_name.
        def association_path(serializer, name, relationship)
          declared = loading_of(serializer, name)[:association]
          return declared unless declared.nil?

          method_name = relationship.respond_to?(:object_method_name) ? relationship.object_method_name : nil
          [ (method_name || name).to_sym ]
        end

        def association_declared?(serializer, name)
          !loading_of(serializer, name)[:association].nil?
        end

        # What the relationship's records always need, relative to them.
        def relationship_preloads(serializer, name)
          normalize_includes(loading_of(serializer, name)[:preload])
        end

        # What the serializer's attributes need, relative to its records.
        def attribute_preloads(serializer)
          return {} unless serializer.respond_to?(:_attribute_preloads)

          serializer._attribute_preloads.values.reduce({}) do |result, includes|
            result.deep_merge(normalize_includes(includes))
          end
        end

        # Converts an ActiveRecord includes argument (symbol, string, array or
        # nested hash) into a new nested hash of symbols, so that
        # { price: :scenario } becomes { price: { scenario: {} } }. Results can
        # then be deep-merged without touching the declaration they came from.
        def normalize_includes(value)
          case value
          when Hash
            value.each_with_object({}) { |(key, nested), result| result[key.to_sym] = normalize_includes(nested) }
          when Array
            value.reduce({}) { |result, item| result.deep_merge(normalize_includes(item)) }
          when Symbol, String
            { value.to_sym => {} }
          when nil
            {}
          else
            raise ArgumentError, "Unsupported ActiveRecord includes value: #{value.inspect}"
          end
        end

        def normalize_association(name, value)
          case value
          when nil, false
            value
          when Symbol, String
            [ value.to_sym ]
          when Array
            steps = value.flatten
            if steps.empty? || !steps.all? { |step| step.is_a?(Symbol) || step.is_a?(String) }
              raise ArgumentError, "association: for :#{name} must list one or more association names, got #{value.inspect}"
            end

            steps.map(&:to_sym)
          else
            raise ArgumentError,
                  "association: for :#{name} must be an association name, an array of them, or false; " \
                  "got #{value.inspect}"
          end
        end

        def declaration_problems(serializer)
          relationships = relationships_of(serializer)
          problems = []

          (serializer._include_allowlist || []).each do |name|
            problems << "allow_includes :#{name} names no relationship" unless relationships.key?(name)
          end

          relationships.each do |name, relationship|
            begin
              static_serializer_of(relationship)
            rescue NameError => e
              problems << "relationship :#{name} cannot resolve its serializer: #{describe_error(e)}"
            end
          end

          problems.concat(preload_problems(serializer))
          problems.map { |problem| "#{serializer.name}: #{problem}" }
        end

        private

        def loading_of(serializer, name)
          return {} unless serializer.respond_to?(:_relationship_loading)

          serializer._relationship_loading[name] || {}
        end

        def preload_problems(serializer)
          attributes = (serializer.respond_to?(:attributes_to_serialize) && serializer.attributes_to_serialize) || {}
          serializer._attribute_preloads.keys.reject { |name| attribute_defined?(serializer, attributes, name) }.map do |name|
            "preload_for_attributes :#{name} names no attribute"
          end
        end

        # jsonapi-serializer stores attributes under their transformed key.
        def attribute_defined?(serializer, attributes, name)
          return true if attributes.key?(name)

          serializer.respond_to?(:run_key_transform) && attributes.key?(serializer.run_key_transform(name))
        end

        # jsonapi-serializer reports every failure to load a serializer class as
        # "cannot resolve", keeping the real error as the cause.
        def describe_error(error)
          cause = error.cause
          return error.message unless cause

          "#{error.message} Caused by #{cause.class}: #{cause.message.lines.first.to_s.strip}"
        end
      end

      included do
        # Rails 4.2 compatible class_attribute declarations (no `default:` keyword).
        # The writers below always assign a new object, so a subclass never
        # writes into the array or hash it inherited from its parent.

        # Relationship names that clients may include. nil allows every
        # relationship.
        class_attribute :_include_allowlist
        self._include_allowlist = nil

        # Format: { relationship_name: { association: [ :a, :b ] or false, preload: { ... } } }
        class_attribute :_relationship_loading
        self._relationship_loading = {}

        # Format: { attribute_name: active_record_includes }
        class_attribute :_attribute_preloads
        self._attribute_preloads = {}
      end

      class_methods do
        # Restricts the relationships that clients may include from this
        # serializer to the ones named. A serializer that never calls this
        # allows every relationship. Paths compose through each serializer's
        # own allowed relationships, so there is nothing to say about depth.
        def allow_includes(*names)
          names = names.flatten
          if names.any? { |name| name.is_a?(Hash) }
            raise ArgumentError,
                  "allow_includes takes relationship names only. Include paths compose from each serializer's " \
                  "relationships, so recursive: and prefix: are no longer needed."
          end

          paths = names.select { |name| name.to_s.include?(".") }
          if paths.any?
            raise ArgumentError, "allow_includes takes relationship names, and these are paths: #{paths.join(", ")}"
          end

          self._include_allowlist = ((_include_allowlist || []) + names.map(&:to_sym)).uniq.freeze
        end

        # The relationships a client may include from this serializer.
        def includable_relationship_names
          IncludeHandling.includable_names(self)
        end

        # jsonapi-serializer's relationship macros, which the lazy_ helpers also
        # call, accept two more options here:
        #
        #   association: the ActiveRecord association the relationship loads
        #                through when it is not the relationship's own name, a
        #                chain such as [ :property, :room_types ], or false
        #                for a relationship that is a plain method.
        #   preload:     associations the related records always need,
        #                relative to those records.
        def has_many(relationship_name, options = {}, &block)
          super(relationship_name, extract_loading_options(relationship_name, options), &block)
        end

        def has_one(relationship_name, options = {}, &block)
          super(relationship_name, extract_loading_options(relationship_name, options), &block)
        end

        def belongs_to(relationship_name, options = {}, &block)
          super(relationship_name, extract_loading_options(relationship_name, options), &block)
        end

        # Declares associations that these attributes always need, whether or not
        # the client included them:
        #
        #   preload_for_attributes :display_name, [ :brand, :city ]
        #
        # The preloads apply wherever this serializer's records are serialized:
        # as the primary records, and under every included relationship that
        # uses this serializer.
        def preload_for_attributes(*attribute_names, includes)
          if attribute_names.empty?
            raise ArgumentError, "preload_for_attributes needs one or more attribute names followed by the includes"
          end

          normalized = IncludeHandling.normalize_includes(includes)
          raise ArgumentError, "preload_for_attributes needs at least one association" if normalized.empty?

          self._attribute_preloads = attribute_names.flatten.each_with_object(_attribute_preloads.dup) do |name, preloads|
            preloads[name.to_sym] = (preloads[name.to_sym] || {}).deep_merge(normalized)
          end
        end

        # Raises Errors::IncludeDeclarationError listing every include
        # declaration on this serializer that cannot work. See
        # JsonapiToolbox::Serializer.verify_includes!.
        def verify_includes!
          JsonapiToolbox::Serializer.verify_includes!(self)
        end

        private

        # Removes this gem's options before jsonapi-serializer sees them, and
        # records them for the relationship. Redeclaring a relationship replaces
        # what was recorded for it, as jsonapi-serializer replaces the
        # relationship itself.
        def extract_loading_options(relationship_name, options)
          options = (options || {}).dup
          loading = {}

          if options.key?(:association)
            association = IncludeHandling.normalize_association(relationship_name, options.delete(:association))
            loading[:association] = association unless association.nil?
          end

          if options.key?(:preload)
            preload = IncludeHandling.normalize_includes(options.delete(:preload))
            loading[:preload] = preload unless preload.empty?
          end

          self._relationship_loading = _relationship_loading.merge(relationship_name.to_sym => loading.freeze)
          options
        end
      end
    end
  end
end
