# frozen_string_literal: true

require "spec_helper"
require "active_record"
require "support/test_database"

# Runs the preloader against SQLite and counts queries. Every model and
# serializer below avoids anything newer than Rails 4.2, so the same file also
# runs on the oldest stack the gem supports. Serializers use the lazy_ helpers,
# as apps do, so linkage is only computed for included relationships.
module PreloaderSpec
  module Current
    mattr_accessor :season, :price_list
  end

  class Supplier < ActiveRecord::Base
    self.table_name = "pl_suppliers"
  end

  class Brand < ActiveRecord::Base
    self.table_name = "pl_brands"
  end

  class City < ActiveRecord::Base
    self.table_name = "pl_cities"
  end

  class Season < ActiveRecord::Base
    self.table_name = "pl_seasons"
  end

  class Currency < ActiveRecord::Base
    self.table_name = "pl_currencies"
  end

  class PriceList < ActiveRecord::Base
    self.table_name = "pl_price_lists"
    has_many :entries, class_name: "PreloaderSpec::PriceListEntry"
  end

  class PriceListEntry < ActiveRecord::Base
    self.table_name = "pl_price_list_entries"
  end

  class Property < ActiveRecord::Base
    self.table_name = "pl_properties"
    has_many :wings, class_name: "PreloaderSpec::Wing"
  end

  class Wing < ActiveRecord::Base
    self.table_name = "pl_wings"
  end

  class Hotel < ActiveRecord::Base
    self.table_name = "pl_hotels"
    belongs_to :supplier, class_name: "PreloaderSpec::Supplier"
    belongs_to :brand, class_name: "PreloaderSpec::Brand"
    belongs_to :city, class_name: "PreloaderSpec::City"
    belongs_to :property, class_name: "PreloaderSpec::Property"
    has_many :room_types, class_name: "PreloaderSpec::RoomType"

    def display_name
      "#{brand.name} #{name}, #{city.name}"
    end

    # Not an association: the request decides which price list is current.
    def current_price_list
      Current.price_list
    end

    def current_price_list_id
      current_price_list && current_price_list.id
    end

    # Not an association either, and nobody declared that.
    def featured_room_type
      room_types.first
    end

    def featured_room_type_id
      featured_room_type && featured_room_type.id
    end
  end

  class RoomType < ActiveRecord::Base
    self.table_name = "pl_room_types"
    belongs_to :hotel, class_name: "PreloaderSpec::Hotel"
    has_many :rates, -> { where(season_id: Current.season.id) }, class_name: "PreloaderSpec::Rate"
  end

  class Rate < ActiveRecord::Base
    self.table_name = "pl_rates"
    belongs_to :currency, class_name: "PreloaderSpec::Currency"

    def price_label
      "#{amount} #{currency.code}"
    end
  end

  class Review < ActiveRecord::Base
    self.table_name = "pl_reviews"
    belongs_to :reviewable, polymorphic: true

    def hotel
      reviewable if reviewable.is_a?(Hotel)
    end

    def room_type
      reviewable if reviewable.is_a?(RoomType)
    end

    def hotel_id
      hotel && hotel.id
    end

    def room_type_id
      room_type && room_type.id
    end
  end

  # A value object that wraps a record, like an action's result.
  ImportRun = Struct.new(:id, :hotel, :hotel_id)

  class CurrencySerializer
    include JsonapiToolbox::Serializer::Base

    attributes :code
  end

  class RateSerializer
    include JsonapiToolbox::Serializer::Base

    attributes :amount, :price_label
    preload_for_attributes :price_label, :currency
    lazy_belongs_to :currency, serializer: CurrencySerializer
  end

  class PriceListEntrySerializer
    include JsonapiToolbox::Serializer::Base
  end

  class PriceListSerializer
    include JsonapiToolbox::Serializer::Base

    attributes :name
    lazy_has_many :entries, serializer: PriceListEntrySerializer
  end

  class WingSerializer
    include JsonapiToolbox::Serializer::Base

    attributes :name
  end

  class RoomTypeSerializer
    include JsonapiToolbox::Serializer::Base

    attributes :name
    lazy_has_many :rates, serializer: RateSerializer

    # Builds new objects on every call, as a method that runs its own query does.
    lazy_has_many :fresh_rates, serializer: RateSerializer, association: false do |room_type|
      Rate.where(room_type_id: room_type.id, season_id: Current.season.id).to_a
    end
  end

  class HotelSerializer
    include JsonapiToolbox::Serializer::Base

    attributes :display_name
    preload_for_attributes :display_name, [ :brand, :city ]

    lazy_belongs_to :supplier
    lazy_has_many :room_types, serializer: RoomTypeSerializer
    lazy_has_many :wings, serializer: WingSerializer, association: [ :property, :wings ] do |hotel|
      hotel.property.wings
    end
    lazy_has_one :current_price_list, serializer: PriceListSerializer, association: false
    lazy_has_one :featured_room_type, serializer: RoomTypeSerializer
    lazy_has_many :room_types_with_rates, serializer: RoomTypeSerializer,
             association: :room_types, preload: { rates: :currency } do |hotel|
      hotel.room_types
    end
    lazy_has_many :listed_room_types, serializer: RoomTypeSerializer, association: :room_types,
             if: ->(hotel, _params) { hotel.name != "Unlisted" } do |hotel|
      hotel.room_types
    end
    lazy_has_many :misnamed_room_types, serializer: RoomTypeSerializer, association: :rooms do |hotel|
      hotel.room_types
    end
  end

  class SupplierSerializer
    include JsonapiToolbox::Serializer::Base

    attributes :name
  end

  class ReviewSerializer
    include JsonapiToolbox::Serializer::Base

    attributes :body
    lazy_belongs_to :hotel, serializer: HotelSerializer, association: :reviewable
    lazy_belongs_to :room_type, serializer: RoomTypeSerializer, association: :reviewable
  end

  class ImportRunSerializer
    include JsonapiToolbox::Serializer::Base

    lazy_belongs_to :hotel, serializer: HotelSerializer
  end
end

RSpec.describe JsonapiToolbox::Serializer::Preloader do
  before(:all) do
    TestDatabase.setup!
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table(:pl_suppliers, force: true) { |t| t.string :name }
      create_table(:pl_brands, force: true) { |t| t.string :name }
      create_table(:pl_cities, force: true) { |t| t.string :name }
      create_table(:pl_seasons, force: true) { |t| t.string :name }
      create_table(:pl_currencies, force: true) { |t| t.string :code }
      create_table(:pl_price_lists, force: true) { |t| t.string :name }
      create_table(:pl_price_list_entries, force: true) { |t| t.integer :price_list_id }
      create_table(:pl_properties, force: true) { |t| t.string :name }
      create_table(:pl_wings, force: true) do |t|
        t.string :name
        t.integer :property_id
      end
      create_table(:pl_hotels, force: true) do |t|
        t.string :name
        t.integer :supplier_id
        t.integer :brand_id
        t.integer :city_id
        t.integer :property_id
      end
      create_table(:pl_room_types, force: true) do |t|
        t.string :name
        t.integer :hotel_id
      end
      create_table(:pl_rates, force: true) do |t|
        t.integer :room_type_id
        t.integer :season_id
        t.integer :currency_id
        t.integer :amount
      end
      create_table(:pl_reviews, force: true) do |t|
        t.string :body
        t.string :reviewable_type
        t.integer :reviewable_id
      end
    end
  end

  after(:all) { TestDatabase.teardown! }

  let(:summer) { PreloaderSpec::Season.create!(name: "Summer") }
  let(:winter) { PreloaderSpec::Season.create!(name: "Winter") }
  let(:euro) { PreloaderSpec::Currency.create!(code: "EUR") }
  let(:price_list) do
    PreloaderSpec::PriceList.create!(name: "2027").tap do |list|
      2.times { PreloaderSpec::PriceListEntry.create!(price_list_id: list.id) }
    end
  end

  before do
    PreloaderSpec::Current.season = summer
    PreloaderSpec::Current.price_list = price_list
  end

  after do
    PreloaderSpec::Current.season = nil
    PreloaderSpec::Current.price_list = nil
  end

  # Two room types per hotel, each with a summer rate and a winter rate.
  def create_hotel(name)
    property = PreloaderSpec::Property.create!(name: "#{name} property")
    2.times { |i| PreloaderSpec::Wing.create!(name: "Wing #{i}", property_id: property.id) }
    hotel = PreloaderSpec::Hotel.create!(
      name: name,
      supplier: PreloaderSpec::Supplier.create!(name: "#{name} supplier"),
      brand: PreloaderSpec::Brand.create!(name: "Seaside"),
      city: PreloaderSpec::City.create!(name: "Lisbon"),
      property: property
    )
    2.times do |i|
      room_type = PreloaderSpec::RoomType.create!(name: "Room #{i}", hotel_id: hotel.id)
      [ summer, winter ].each_with_index do |season, s|
        PreloaderSpec::Rate.create!(room_type_id: room_type.id, season_id: season.id, currency_id: euro.id,
                                    amount: 100 + (10 * i) + s)
      end
    end
    hotel
  end

  def load_hotels(*hotels)
    PreloaderSpec::Hotel.where(id: hotels.map(&:id)).order(:id).to_a
  end

  def count_queries
    count = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      count += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name])
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # Preloads, then serializes, and returns [preload queries, serializing
  # queries, payload].
  def preload_and_serialize(serializer, resource, include_paths, is_collection: nil)
    tree = JsonapiToolbox::Serializer::IncludeTree.parse(include_paths)
    params = nil
    preload_queries = count_queries do
      params = described_class.call(serializer, resource, tree, params: {}, is_collection: is_collection)
    end

    payload = nil
    serialize_queries = count_queries do
      options = { include: include_paths, params: params }
      options[:is_collection] = is_collection unless is_collection.nil?
      payload = serializer.new(resource, options).serializable_hash
    end
    [ preload_queries, serialize_queries, payload ]
  end

  def included_of_type(payload, type)
    (payload[:included] || []).select { |record| record[:type] == type }
  end

  it "loads a nested include with one query per association, and serializing then runs none" do
    hotels = load_hotels(create_hotel("Mar"), create_hotel("Sol"))

    preload_queries, serialize_queries, payload =
      preload_and_serialize(PreloaderSpec::HotelSerializer, hotels, %w[supplier room_types.rates])

    # brand, city (display_name); supplier; room_types; rates; currency (price_label)
    expect(preload_queries).to eq(6)
    expect(serialize_queries).to eq(0)
    expect(payload[:data].map { |hotel| hotel[:attributes][:display_name] }).to eq([ "Seaside Mar, Lisbon", "Seaside Sol, Lisbon" ])
    expect(included_of_type(payload, :rates).map { |rate| rate[:attributes][:price_label] })
      .to contain_exactly("100 EUR", "110 EUR", "100 EUR", "110 EUR")
  end

  it "applies a scoped association's scope when it preloads, here the current season" do
    hotels = load_hotels(create_hotel("Mar"))
    PreloaderSpec::Current.season = winter

    _, serialize_queries, payload = preload_and_serialize(PreloaderSpec::HotelSerializer, hotels, %w[room_types.rates])

    expect(serialize_queries).to eq(0)
    expect(included_of_type(payload, :rates).map { |rate| rate[:attributes][:amount] }).to contain_exactly(101, 111)
  end

  it "preloads attribute preloads for the primary records when nothing is included" do
    hotels = load_hotels(create_hotel("Mar"), create_hotel("Sol"))

    preload_queries, serialize_queries, = preload_and_serialize(PreloaderSpec::HotelSerializer, hotels, [])

    expect(preload_queries).to eq(2)
    expect(serialize_queries).to eq(0)
  end

  # jsonapi-serializer only treats an Enumerable as a collection, and a Rails
  # 4.2 relation is not one, so the caller says so with is_collection. The
  # preloader follows the serializer's decision either way.
  it "accepts a single record or a relation as well as an array" do
    hotel = create_hotel("Mar")

    _, single_queries, = preload_and_serialize(PreloaderSpec::HotelSerializer, load_hotels(hotel).first, %w[room_types])
    _, relation_queries, payload = preload_and_serialize(
      PreloaderSpec::HotelSerializer, PreloaderSpec::Hotel.where(id: hotel.id), %w[room_types], is_collection: true
    )

    expect([ single_queries, relation_queries ]).to eq([ 0, 0 ])
    expect(payload[:data].size).to eq(1)
  end

  it "loads typed views of a polymorphic association, continuing only with each view's records" do
    hotel = create_hotel("Mar")
    room_type = PreloaderSpec::RoomType.where(hotel_id: hotel.id).first
    PreloaderSpec::Review.create!(body: "Lovely", reviewable: hotel)
    PreloaderSpec::Review.create!(body: "Small", reviewable: room_type)
    reviews = PreloaderSpec::Review.order(:id).to_a

    preload_queries, serialize_queries, payload = preload_and_serialize(
      PreloaderSpec::ReviewSerializer, reviews, %w[hotel.room_types room_type.rates]
    )

    # reviewable as hotels and room types; the hotel's brand, city and room
    # types; the room type's rates, and their currency
    expect(preload_queries).to eq(7)
    expect(serialize_queries).to eq(0)
    expect(included_of_type(payload, :hotels).size).to eq(1)
    expect(included_of_type(payload, :rates).size).to eq(1)
  end

  it "loads through a chain of associations, and nests deeper includes under its last step" do
    hotels = load_hotels(create_hotel("Mar"))

    preload_queries, serialize_queries, payload = preload_and_serialize(PreloaderSpec::HotelSerializer, hotels, %w[wings])

    # brand, city; property; wings
    expect(preload_queries).to eq(4)
    expect(serialize_queries).to eq(0)
    expect(included_of_type(payload, :wings).size).to eq(2)
  end

  it "asks the serializer for a relationship that is not an association, then preloads below it" do
    hotels = load_hotels(create_hotel("Mar"), create_hotel("Sol"))

    preload_queries, serialize_queries, payload = preload_and_serialize(
      PreloaderSpec::HotelSerializer, hotels, %w[current_price_list.entries]
    )

    # brand, city; the price list's entries
    expect(preload_queries).to eq(3)
    expect(serialize_queries).to eq(0)
    expect(included_of_type(payload, :price_list_entries).size).to eq(2)
  end

  it "starts from a value object that is not an ActiveRecord record" do
    hotel = load_hotels(create_hotel("Mar")).first
    run = PreloaderSpec::ImportRun.new(1, hotel, hotel.id)

    preload_queries, serialize_queries, payload = preload_and_serialize(
      PreloaderSpec::ImportRunSerializer, run, %w[hotel.room_types]
    )

    expect(preload_queries).to eq(3)
    expect(serialize_queries).to eq(0)
    expect(included_of_type(payload, :room_types).size).to eq(2)
  end

  it "reuses the records it fetched, even from a relationship that builds new objects on every call" do
    hotels = load_hotels(create_hotel("Mar"))

    preload_queries, serialize_queries, payload = preload_and_serialize(
      PreloaderSpec::HotelSerializer, hotels, %w[room_types.fresh_rates]
    )

    # brand, city; room_types; one fresh_rates query per room type; currency
    expect(preload_queries).to eq(6)
    expect(serialize_queries).to eq(0)
    expect(included_of_type(payload, :rates).size).to eq(2)
  end

  it "preloads a relationship's own preload: on its records" do
    hotels = load_hotels(create_hotel("Mar"))
    tree = JsonapiToolbox::Serializer::IncludeTree.parse(%w[room_types_with_rates])

    described_class.call(PreloaderSpec::HotelSerializer, hotels, tree, params: {})

    room_types = hotels.first.room_types.to_a
    expect(room_types.map { |room_type| room_type.association(:rates).loaded? }).to all(be true)
    expect(room_types.flat_map(&:rates).map { |rate| rate.association(:currency).loaded? }).to all(be true)
  end

  it "skips the parents for which a relationship's if: condition is false" do
    listed, unlisted = load_hotels(create_hotel("Mar"), create_hotel("Unlisted"))
    tree = JsonapiToolbox::Serializer::IncludeTree.parse(%w[listed_room_types.rates])

    described_class.call(PreloaderSpec::HotelSerializer, [ listed, unlisted ], tree, params: {})

    expect(listed.room_types.map { |room_type| room_type.association(:rates).loaded? }).to all(be true)
    expect(unlisted.room_types.map { |room_type| room_type.association(:rates).loaded? }).to all(be false)
  end

  it "raises when a relationship has no association and does not say so" do
    hotels = load_hotels(create_hotel("Mar"))
    tree = JsonapiToolbox::Serializer::IncludeTree.parse(%w[featured_room_type])

    expect { described_class.call(PreloaderSpec::HotelSerializer, hotels, tree, params: {}) }
      .to raise_error(JsonapiToolbox::Errors::IncludeDeclarationError) { |error|
        expect(error.message).to include(
          "PreloaderSpec::HotelSerializer#featured_room_type: PreloaderSpec::Hotel has no association named :featured_room_type",
          "Declare association: false if featured_room_type is a plain method"
        )
      }
  end

  it "raises when association: names an association the model lacks" do
    hotels = load_hotels(create_hotel("Mar"))
    tree = JsonapiToolbox::Serializer::IncludeTree.parse(%w[misnamed_room_types])

    expect { described_class.call(PreloaderSpec::HotelSerializer, hotels, tree, params: {}) }
      .to raise_error(JsonapiToolbox::Errors::IncludeDeclarationError, /association: names :rooms, but PreloaderSpec::Hotel has no association with that name/)
  end

  it "checks the include tree before loading anything" do
    hotels = load_hotels(create_hotel("Mar"))
    tree = JsonapiToolbox::Serializer::IncludeTree.parse(%w[nope])

    expect { described_class.call(PreloaderSpec::HotelSerializer, hotels, tree, params: {}) }
      .to raise_error(JsonapiToolbox::Errors::InvalidIncludeError)
  end
end
