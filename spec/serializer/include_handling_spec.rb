# frozen_string_literal: true

require "spec_helper"
require "set"

RSpec.describe JsonapiToolbox::Serializer::IncludeHandling do
  # Each example gets its own namespace, so serializers never collide.
  module IncludeHandlingSpecNamespaces
    def self.next_name
      @count = (@count || 0) + 1
      "IncludeHandlingSpec#{@count}"
    end
  end

  let(:namespace) { IncludeHandlingSpecNamespaces.next_name }

  # Serializers need a constant name before including Base (it derives the JSON:API
  # type from the name), and symbol `serializer:` options resolve within the namespace.
  def define_serializer(name, &body)
    klass = stub_const("#{namespace}::#{name}Serializer", Class.new)
    klass.include(JsonapiToolbox::Serializer::Base)
    klass.class_eval { attributes :name }
    klass.class_eval(&body) if body
    klass
  end

  def loading(serializer, name)
    described_class.association_path(serializer, name, serializer.relationships_to_serialize[name])
  end

  # Every serializer includes this module, and Ruby looks up constants in a
  # class's ancestors before Object.
  it "does not hide the app's own constants inside a serializer" do
    entry = stub_const("Entry", Class.new)
    serializer = define_serializer("Ledger")

    expect(serializer.class_eval("Entry")).to equal(entry)
    expect(described_class.constants).to eq([ :ClassMethods ])
  end

  describe ".allow_includes" do
    it "lets clients include every relationship when a serializer declares nothing" do
      kid = define_serializer("Kid")
      parent = define_serializer("Parent") do
        lazy_has_many :kids, serializer: kid
        lazy_belongs_to :owner, serializer: kid
      end

      expect(parent.includable_relationship_names).to eq([ :kids, :owner ])
    end

    it "restricts includes to the relationships named, across several calls" do
      kid = define_serializer("Kid")
      parent = define_serializer("Parent") do
        lazy_has_many :kids, serializer: kid
        lazy_belongs_to :owner, serializer: kid
        lazy_belongs_to :agent, serializer: kid
        allow_includes :kids
        allow_includes :agent
      end

      expect(parent.includable_relationship_names).to eq([ :kids, :agent ])
    end

    it "lets a subclass add names without changing its parent" do
      kid = define_serializer("Kid")
      parent = define_serializer("Parent") do
        lazy_has_many :kids, serializer: kid
        lazy_belongs_to :owner, serializer: kid
        allow_includes :kids
      end
      child = stub_const("#{namespace}::ChildSerializer", Class.new(parent))
      child.allow_includes :owner

      expect(child.includable_relationship_names).to eq([ :kids, :owner ])
      expect(parent.includable_relationship_names).to eq([ :kids ])
    end

    it "rejects the recursive: and prefix: options, and paths" do
      expect { define_serializer("Parent") { allow_includes :kids, recursive: true } }
        .to raise_error(ArgumentError, /recursive: and prefix: are no longer needed/)
      expect { define_serializer("Parent") { allow_includes :"kids.toys" } }
        .to raise_error(ArgumentError, "allow_includes takes relationship names, and these are paths: kids.toys")
    end
  end

  describe "loading options on relationships" do
    let(:kid) { define_serializer("Kid") }

    it "loads through the association with the relationship's name by default" do
      kid_serializer = kid
      parent = define_serializer("Parent") { lazy_has_many :kids, serializer: kid_serializer }

      expect(loading(parent, :kids)).to eq([ :kids ])
    end

    it "uses jsonapi-serializer's object_method_name as the default association" do
      kid_serializer = kid
      parent = define_serializer("Parent") do
        lazy_has_many :kids, serializer: kid_serializer, object_method_name: :visible_kids
      end

      expect(loading(parent, :kids)).to eq([ :visible_kids ])
    end

    it "records association: and preload:, and keeps them away from jsonapi-serializer" do
      kid_serializer = kid
      parent = define_serializer("Parent") do
        lazy_belongs_to :post, serializer: kid_serializer, association: :commentable
        lazy_has_many :wings, serializer: kid_serializer, association: [ :property, :wings ], preload: { rooms: :beds }
        lazy_has_one :current_plan, serializer: kid_serializer, association: false
      end

      expect(loading(parent, :post)).to eq([ :commentable ])
      expect(loading(parent, :wings)).to eq([ :property, :wings ])
      expect(loading(parent, :current_plan)).to eq(false)
      expect(described_class.relationship_preloads(parent, :wings)).to eq(rooms: { beds: {} })
      expect(parent.relationships_to_serialize[:wings].lazy_load_data).to eq(true)
    end

    it "replaces the options when a relationship is declared again, in that class only" do
      kid_serializer = kid
      parent = define_serializer("Parent") do
        lazy_belongs_to :post, serializer: kid_serializer, association: :commentable
      end
      child = stub_const("#{namespace}::ChildSerializer", Class.new(parent))
      child.lazy_belongs_to :post, serializer: kid

      expect(loading(child, :post)).to eq([ :post ])
      expect(loading(parent, :post)).to eq([ :commentable ])
    end

    it "rejects association: values that name no association" do
      kid_serializer = kid
      expect { define_serializer("Parent") { lazy_has_many :kids, serializer: kid_serializer, association: [] } }
        .to raise_error(ArgumentError, /must list one or more association names/)
      expect { define_serializer("Parent") { lazy_has_many :kids, serializer: kid_serializer, association: true } }
        .to raise_error(ArgumentError, /must be an association name, an array of them, or false/)
    end
  end

  describe ".preload_for_attributes" do
    it "accepts several attributes and merges repeated declarations" do
      serializer = define_serializer("Hotel") do
        attributes :display_name, :address
        preload_for_attributes :display_name, :address, :city
        preload_for_attributes :address, { city: :country }
      end

      expect(serializer._attribute_preloads).to eq(display_name: { city: {} }, address: { city: { country: {} } })
      expect(described_class.attribute_preloads(serializer)).to eq(city: { country: {} })
    end

    it "needs attribute names and at least one association" do
      expect { define_serializer("Hotel") { preload_for_attributes({ city: :country }) } }
        .to raise_error(ArgumentError, /one or more attribute names/)
      expect { define_serializer("Hotel") { preload_for_attributes :display_name, [] } }
        .to raise_error(ArgumentError, /at least one association/)
    end
  end

  describe ".verify_includes!" do
    it "returns true when every declaration can work" do
      kid = define_serializer("Kid")
      parent = define_serializer("Parent") do
        lazy_has_many :kids, serializer: kid
        allow_includes :kids
        preload_for_attributes :name, :brand
      end

      expect(parent.verify_includes!).to eq(true)
    end

    it "raises one error listing every problem" do
      kid = define_serializer("Kid")
      parent = define_serializer("Parent") do
        lazy_has_many :kids, serializer: kid
        lazy_belongs_to :reconciliation_session
        allow_includes :kids, :ghost
        preload_for_attributes :missing_attribute, :kids
      end

      expect { parent.verify_includes! }.to raise_error(JsonapiToolbox::Errors::IncludeDeclarationError) { |error|
        expect(error.problems.size).to eq(3)
        expect(error.problems[0]).to eq("#{parent.name}: allow_includes :ghost names no relationship")
        expect(error.problems[1]).to start_with(
          "#{parent.name}: relationship :reconciliation_session cannot resolve its serializer:"
        )
        expect(error.problems[2]).to eq("#{parent.name}: preload_for_attributes :missing_attribute names no attribute")
      }
    end

    it "checks any enumerable of serializers, and rejects anything else or nothing, so it cannot pass vacuously" do
      good = define_serializer("Good")
      bad = define_serializer("Bad") { allow_includes :ghost }
      declaration_error = JsonapiToolbox::Errors::IncludeDeclarationError

      expect(JsonapiToolbox::Serializer.verify_includes!([ good ])).to eq(true)
      expect { JsonapiToolbox::Serializer.verify_includes!(Set[good, bad]) }.to raise_error(declaration_error)
      expect { JsonapiToolbox::Serializer.verify_includes!([ bad ].lazy) }.to raise_error(declaration_error)
      expect { JsonapiToolbox::Serializer.verify_includes!(bad.name) }
        .to raise_error(ArgumentError, /expects serializer classes/)
      expect { JsonapiToolbox::Serializer.verify_includes!([]) }.to raise_error(ArgumentError, /no serializers/)
    end
  end
end
