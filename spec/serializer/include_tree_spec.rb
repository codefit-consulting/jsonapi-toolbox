# frozen_string_literal: true

require "spec_helper"

RSpec.describe JsonapiToolbox::Serializer::IncludeTree do
  module IncludeTreeSpec
    class RateSerializer
      include JsonapiToolbox::Serializer::Base
    end

    class RoomTypeSerializer
      include JsonapiToolbox::Serializer::Base

      lazy_has_many :rates, serializer: RateSerializer
      lazy_belongs_to :hotel, serializer: :hotel
    end

    class OwnerSerializer
      include JsonapiToolbox::Serializer::Base
    end

    class HotelSerializer
      include JsonapiToolbox::Serializer::Base

      lazy_has_many :room_types, serializer: RoomTypeSerializer
      lazy_belongs_to :owner, serializer: OwnerSerializer
      lazy_belongs_to :listing, polymorphic: true
      lazy_belongs_to :ghost_town
    end

    class PublicHotelSerializer
      include JsonapiToolbox::Serializer::Base

      lazy_has_many :room_types, serializer: RoomTypeSerializer
      lazy_belongs_to :owner, serializer: OwnerSerializer
      allow_includes :room_types
    end
  end

  after { JsonapiToolbox::Serializer.reset_configuration! }

  def validate(serializer, include_value)
    described_class.validate!(serializer, described_class.parse(include_value))
  end

  describe ".parse" do
    it "builds a tree of relationship names, merging shared prefixes" do
      expect(described_class.parse("room_types.rates, room_types.hotel,owner"))
        .to eq(room_types: { rates: {}, hotel: {} }, owner: {})
    end

    it "accepts an array of paths, and nothing" do
      expect(described_class.parse(%w[owner room_types.rates])).to eq(owner: {}, room_types: { rates: {} })
      expect(described_class.parse(nil)).to eq({})
      expect(described_class.parse(" , ")).to eq({})
    end
  end

  describe ".paths" do
    it "lists each distinct path once, without surrounding spaces" do
      expect(described_class.paths(" owner,room_types.rates ,owner")).to eq(%w[owner room_types.rates])
    end
  end

  describe ".validate!" do
    let(:hotel) { IncludeTreeSpec::HotelSerializer }

    it "accepts paths through relationships the serializers allow" do
      expect(validate(hotel, "owner,room_types.rates")).to eq(true)
    end

    it "follows a cycle as far as the depth limit, and no further" do
      JsonapiToolbox::Serializer.configure { |config| config.max_include_depth = 4 }

      expect(validate(hotel, "room_types.hotel.room_types.hotel")).to eq(true)
      expect { validate(hotel, "room_types.hotel.room_types.hotel.owner") }
        .to raise_error(JsonapiToolbox::Errors::InvalidIncludeError) { |error|
          expect(error.message).to eq(
            'Invalid include "room_types.hotel.room_types.hotel.owner": Include paths can have at most 4 segments.'
          )
        }
    end

    it "names the failing segment, its type and what can be included there" do
      expect { validate(hotel, "room_types.views") }
        .to raise_error(JsonapiToolbox::Errors::InvalidIncludeError) { |error|
          expect(error.message).to eq(
            'Invalid include "room_types.views": "views" is not a relationship of room_types. ' \
            "Includable here: rates, hotel."
          )
          expect([ error.path, error.segment, error.includable ]).to eq([ "room_types.views", "views", %w[rates hotel] ])
        }
    end

    it "rejects a relationship that allow_includes leaves out" do
      expect { validate(IncludeTreeSpec::PublicHotelSerializer, "owner") }
        .to raise_error(JsonapiToolbox::Errors::InvalidIncludeError,
                        'Invalid include "owner": "owner" cannot be included from public_hotels. ' \
                        "Includable here: room_types.")
    end

    it "allows a relationship whose serializer is chosen per record, but nothing below it" do
      expect(validate(hotel, "listing")).to eq(true)
      expect { validate(hotel, "listing.address") }
        .to raise_error(JsonapiToolbox::Errors::InvalidIncludeError,
                        'Invalid include "listing": "listing" can hold records of several types, ' \
                        "so nothing can be included below it.")
    end

    it "reports a relationship whose serializer class does not exist as a declaration problem" do
      expect { validate(hotel, "ghost_town") }
        .to raise_error(JsonapiToolbox::Errors::IncludeDeclarationError,
                        /IncludeTreeSpec::HotelSerializer: relationship :ghost_town cannot resolve its serializer/)
    end
  end

  describe ".serializers_by_type" do
    it "maps the root type and every type the tree reaches to its serializer" do
      tree = described_class.parse("room_types.rates")

      expect(described_class.serializers_by_type(IncludeTreeSpec::HotelSerializer, tree)).to eq(
        "hotels" => IncludeTreeSpec::HotelSerializer,
        "room_types" => IncludeTreeSpec::RoomTypeSerializer,
        "rates" => IncludeTreeSpec::RateSerializer
      )
    end
  end
end
