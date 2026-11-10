# frozen_string_literal: true

require "spec_helper"
require "jsonapi_toolbox/client"

# JSON:API requires every resource id to be a string. Both SwimTrek apps
# build their cross-app references as `klass.new(id: some_integer)`, and
# json_api_client copies whatever Ruby holds straight into the request body,
# so these ids used to go out as JSON numbers.
#
# Each example drives a real save through the Faraday test adapter and reads
# the serialised body back, so what is asserted is the JSON that reaches the
# socket rather than the intermediate hash.
RSpec.describe "string ids in client request bodies" do
  around do |ex|
    original = Faraday.default_adapter
    Faraday.default_adapter = :test
    JsonapiToolbox::Client.configure { |c| c.persistent_connections = false }
    ex.run
  ensure
    Faraday.default_adapter = original
    JsonapiToolbox::Client.reset_configuration!
  end

  let(:stubs) { Faraday::Adapter::Test::Stubs.new }

  let(:departure_class) do
    s = stubs
    Class.new(JsonapiToolbox::Client::Base) do
      self.site = "https://example.com/api/"
      def self.resource_name
        "departure"
      end
      connection do |conn|
        conn.faraday.builder.adapter :test, s
      end
    end
  end

  let(:tag_class) do
    s = stubs
    Class.new(JsonapiToolbox::Client::Base) do
      self.site = "https://example.com/api/"
      def self.resource_name
        "tag"
      end
      connection do |conn|
        conn.faraday.builder.adapter :test, s
      end
    end
  end

  let(:booking_class) do
    s = stubs
    Class.new(JsonapiToolbox::Client::Base) do
      self.site = "https://example.com/api/"
      def self.resource_name
        "booking"
      end
      has_one :departure
      has_many :tags
      connection do |conn|
        conn.faraday.builder.adapter :test, s
      end
    end
  end

  # The body of each request the adapter saw, parsed, in request order.
  let(:sent_bodies) { [] }

  def json_response(id)
    [
      200,
      { "Content-Type" => "application/vnd.api+json" },
      { "data" => { "type" => "bookings", "id" => id, "attributes" => {} } }.to_json
    ]
  end

  before do
    bodies = sent_bodies

    stubs.post("/api/bookings") do |env|
      bodies << JSON.parse(env.body)
      json_response("1")
    end

    stubs.patch("/api/bookings/88") do |env|
      bodies << JSON.parse(env.body)
      json_response("88")
    end
  end

  # The reference the apps build: a persisted stand-in carrying nothing but
  # the id, so json_api_client serialises it as a relationship rather than
  # trying to save it.
  def departure_ref(id)
    departure_class.new(id: id).tap(&:mark_as_persisted!)
  end

  def relationships
    sent_bodies.last.fetch("data").fetch("relationships")
  end

  it "sends a to-one relationship's Integer id as a string" do
    booking = booking_class.new(name: "Lefkada")
    booking.departure = departure_ref(77)
    booking.save

    expect(relationships).to eq("departure" => { "data" => { "type" => "departures", "id" => "77" } })
  end

  it "sends every id in a to-many relationship as a string" do
    booking = booking_class.new(name: "Lefkada")
    booking.tags = [ tag_class.new(id: 1), tag_class.new(id: 2) ]
    booking.save

    expect(relationships.fetch("tags").fetch("data")).to eq(
      [
        { "type" => "tags", "id" => "1" },
        { "type" => "tags", "id" => "2" }
      ]
    )
  end

  it "sends a relationship assigned as a raw type/id hash as a string id" do
    booking = booking_class.new(name: "Lefkada")
    booking.departure = { data: { type: "departures", id: 99 } }
    booking.save

    expect(relationships).to eq("departure" => { "data" => { "type" => "departures", "id" => "99" } })
  end

  it "sends the record's own id as a string when updating" do
    booking = booking_class.new(id: 88).tap(&:mark_as_persisted!)
    booking.name = "Lefkada"
    booking.save

    expect(sent_bodies.last.fetch("data")).to include("id" => "88")
  end

  # Earlier work made a to-one relationship sent as null mean "clear it", so
  # null must survive untouched. "" or "nil" would read as a resource id.
  it "leaves a nil to-one relationship as null" do
    booking = booking_class.new(name: "Lefkada")
    booking.departure = nil
    booking.save

    expect(relationships).to eq("departure" => { "data" => nil })
    expect(relationships.fetch("departure").fetch("data")).to be_nil
  end

  it "leaves an emptied to-many relationship as an empty array" do
    booking = booking_class.new(name: "Lefkada")
    booking.tags = []
    booking.save

    expect(relationships).to eq("tags" => { "data" => [] })
  end

  # The coercion happens as the body is built. Reading an id back in Ruby
  # still gives the type that was assigned, so app code comparing ids
  # numerically is unaffected.
  it "does not change the id attribute held in Ruby" do
    ref = departure_ref(77)

    expect(ref.id).to eq(77)
    expect(ref.id).to be_a(Integer)
  end
end
