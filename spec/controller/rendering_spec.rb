# frozen_string_literal: true

require "spec_helper"
require "active_record"
require "support/test_database"

RSpec.describe JsonapiToolbox::Controller::Rendering do
  module RenderingSpec
    class Author < ActiveRecord::Base
      self.table_name = "rd_authors"
    end

    class Post < ActiveRecord::Base
      self.table_name = "rd_posts"
      belongs_to :author, class_name: "RenderingSpec::Author"
    end

    class AuthorSerializer
      include JsonapiToolbox::Serializer::Base

      attributes :name
    end

    class PostSerializer
      include JsonapiToolbox::Serializer::Base

      attributes :title
      attribute(:greeting) { |_post, params| params[:greeting] }
      lazy_belongs_to :author, serializer: AuthorSerializer
    end
  end

  # Rendering and include validation, without booting a controller.
  let(:controller_class) do
    Class.new do
      def self.before_action(*); end

      include JsonapiToolbox::Controller::Validation
      include JsonapiToolbox::Controller::Rendering

      attr_reader :params, :rendered

      def initialize(params = {})
        @params = params
      end

      def serializer_class
        RenderingSpec::PostSerializer
      end

      def render(**options)
        @rendered = options
      end

      public :render_jsonapi, :render_jsonapi_error, :validate_includes
    end
  end

  before(:all) do
    TestDatabase.setup!
    ActiveRecord::Schema.verbose = false
    ActiveRecord::Schema.define do
      create_table(:rd_authors, force: true) { |t| t.string :name }
      create_table(:rd_posts, force: true) do |t|
        t.string :title
        t.integer :author_id
      end
    end
  end

  after(:all) { TestDatabase.teardown! }

  before do
    RenderingSpec::Post.delete_all
    RenderingSpec::Author.delete_all
  end

  # Three posts, each by a different author.
  let(:posts) do
    3.times do |i|
      author = RenderingSpec::Author.create!(name: "Author #{i}")
      RenderingSpec::Post.create!(title: "Post #{i}", author_id: author.id)
    end
    RenderingSpec::Post.order(:id).to_a
  end

  def controller_for(params = {})
    controller_class.new(params).tap { |controller| controller.validate_includes if params[:include] }
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

  it "preloads the requested includes before serializing" do
    records = posts
    controller = controller_for(include: "author")

    queries = count_queries { controller.render_jsonapi(records) }

    expect(queries).to eq(1)
    expect(controller.rendered[:json][:included].map { |author| author[:attributes][:name] })
      .to eq([ "Author 0", "Author 1", "Author 2" ])
  end

  it "leaves loading to the action when it passes preload: false" do
    records = posts
    controller = controller_for(include: "author")

    queries = count_queries { controller.render_jsonapi(records, preload: false) }

    expect(queries).to eq(3)
  end

  it "passes the action's params through to the serializer" do
    controller = controller_for(include: "author")

    controller.render_jsonapi(posts.first, params: { greeting: "hello" })

    expect(controller.rendered[:json][:data][:attributes][:greeting]).to eq("hello")
  end

  it "checks an include list that the action passes itself" do
    controller = controller_for

    expect { controller.render_jsonapi(posts, include: [ "editor" ]) }
      .to raise_error(JsonapiToolbox::Errors::InvalidIncludeError, /"editor" is not a relationship of posts/)
  end

  it "renders an invalid include as a 400 whose detail is the error message" do
    controller = controller_for
    error = JsonapiToolbox::Errors::InvalidIncludeError.new("Invalid include \"editor\": nope.", path: "editor")

    controller.render_jsonapi_error(error)

    expect(controller.rendered[:status]).to eq(:bad_request)
    expect(controller.rendered[:json][:errors].first).to include(
      status: "400", detail: "Invalid include \"editor\": nope.", source: { parameter: "include" }
    )
  end
end
