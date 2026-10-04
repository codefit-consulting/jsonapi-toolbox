# frozen_string_literal: true

require "spec_helper"
require "action_controller"

RSpec.describe JsonapiToolbox::Controller::Validation do
  module ValidationSpec
    class AddressSerializer
      include JsonapiToolbox::Serializer::Base

      attributes :city
    end

    class AuthorSerializer
      include JsonapiToolbox::Serializer::Base

      attributes :name, :email
      lazy_belongs_to :address, serializer: AddressSerializer
    end

    class PostSerializer
      include JsonapiToolbox::Serializer::Base

      attributes :title
      lazy_belongs_to :author, serializer: AuthorSerializer
    end
  end

  # The concern's private callbacks, without booting a controller.
  let(:controller_class) do
    Class.new do
      def self.before_action(*); end

      include JsonapiToolbox::Controller::Validation

      attr_reader :params

      def initialize(params)
        @params = ActionController::Parameters.new(params)
      end

      def serializer_class
        ValidationSpec::PostSerializer
      end

      public :validate_includes, :validate_sparse_fieldsets
    end
  end

  def controller_for(params)
    controller_class.new(params).tap do |controller|
      controller.validate_includes if params[:include]
      controller.validate_sparse_fieldsets if params[:fields]
    end
  end

  describe "#validate_includes" do
    it "keeps the include tree and the requested paths for rendering" do
      controller = controller_for(include: "author, author.address")

      expect(controller.instance_variable_get(:@validated_include_tree)).to eq(author: { address: {} })
      expect(controller.instance_variable_get(:@validated_includes)).to eq(%w[author author.address])
    end

    it "rejects a path that cannot be served, naming it" do
      expect { controller_for(include: "author.agent") }
        .to raise_error(JsonapiToolbox::Errors::InvalidIncludeError,
                        'Invalid include "author.agent": "agent" is not a relationship of authors. ' \
                        "Includable here: address.")
    end
  end

  describe "#validate_sparse_fieldsets" do
    # Used to raise NoMethodError (a 500) for any included type, because the
    # old lookup called String#split on symbols.
    it "checks the fieldset of an included type" do
      controller = controller_for(include: "author", fields: { authors: "name" })

      expect(controller.instance_variable_get(:@validated_fields)).to eq(authors: [ :name ])
      expect { controller_for(include: "author", fields: { authors: "name,salary" }) }
        .to raise_error(JsonapiToolbox::Errors::InvalidFieldsError, /salary/)
    end

    it "checks the primary type's fieldset" do
      expect(controller_for(fields: { posts: "title" }).instance_variable_get(:@validated_fields))
        .to eq(posts: [ :title ])
      expect { controller_for(fields: { posts: "body" }) }.to raise_error(JsonapiToolbox::Errors::InvalidFieldsError)
    end

    it "ignores fieldsets for types the response cannot contain" do
      controller = controller_for(fields: { authors: "salary" })

      expect(controller.instance_variable_get(:@validated_fields)).to eq({})
    end
  end
end
