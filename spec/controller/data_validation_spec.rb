# frozen_string_literal: true

require "spec_helper"
require "action_controller"

RSpec.describe JsonapiToolbox::Controller::DataValidation do
  # The concern on its own, without booting a controller.
  let(:controller_class) do
    Class.new do
      include JsonapiToolbox::Controller::DataValidation

      attr_reader :params

      def initialize(params)
        @params = ActionController::Parameters.new(params)
      end
    end
  end

  def validate(relationships, **options)
    params = { data: { type: "departures", id: "1", attributes: { state: "live" }, relationships: relationships } }
    controller_class.new(params).validate_data(permitted_attributes: [ :state ], **options)
  end

  describe "to-one relationships" do
    let(:options) { { permitted_relationships: [ :special_trip_type ] } }

    it "sets the foreign key from the related id" do
      attrs = validate({ special_trip_type: { data: { type: "special_trip_types", id: "113" } } }, **options)

      expect(attrs).to eq("state" => "live", "special_trip_type_id" => "113")
    end

    it "clears the foreign key when data is null" do
      attrs = validate({ special_trip_type: { data: nil } }, **options)

      expect(attrs).to eq("state" => "live", "special_trip_type_id" => nil)
    end

    it "leaves the foreign key alone when the relationship is absent" do
      expect(validate({}, **options)).to eq("state" => "live")
    end

    it "leaves the foreign key alone when the relationship has no data key" do
      attrs = validate({ special_trip_type: { links: { related: "/departures/1/special_trip_type" } } }, **options)

      expect(attrs).to eq("state" => "live")
    end

    # A required relationship counts as present when its data is null, so the
    # foreign key is cleared and the model's own validations decide.
    it "clears the foreign key of a required relationship sent as null" do
      attrs = validate({ package: { data: nil } }, required_relationships: [ :package ])

      expect(attrs).to eq("state" => "live", "package_id" => nil)
    end
  end

  describe "to-many relationships" do
    let(:options) { { permitted_relationships: [ :room_configurations ] } }

    it "sets the ids from the related ids" do
      attrs = validate({ room_configurations: { data: [ { type: "room_configurations", id: "4" },
                                                        { type: "room_configurations", id: "7" } ] } }, **options)

      expect(attrs).to eq("state" => "live", "room_configuration_ids" => %w[4 7])
    end

    it "clears the ids when data is an empty array" do
      attrs = validate({ room_configurations: { data: [] } }, **options)

      expect(attrs).to eq("state" => "live", "room_configuration_ids" => [])
    end
  end
end
