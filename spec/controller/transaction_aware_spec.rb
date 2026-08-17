# frozen_string_literal: true

require "spec_helper"
require "active_record"
require "jsonapi_toolbox"
require "jsonapi_toolbox/transaction"

# Exercises the in-transaction error-handoff path (TransactionAware +
# Rendering). Reproduces the v1 SwimTrek bug where an operation error raised
# while a held transaction was active swallowed the host app's rescue_from
# handlers and always returned 500.
#
# The host below mirrors how a consuming app composes the concerns: the app's
# own rescue_from lines are declared AFTER the include, so under Rails' reverse
# handler scan they outrank any gem handler with no config needed.
RSpec.describe JsonapiToolbox::Controller::TransactionAware do
  # App-specific exception the host wants routed to a 422, distinct from a 500,
  # so the caller can tell "conflict, roll back cleanly" from "the server broke".
  class CannotDeleteWithAllocationsError < StandardError; end

  let(:controller_class) do
    Class.new do
      include ActiveSupport::Rescuable
      include JsonapiToolbox::Controller::Rendering
      include JsonapiToolbox::Controller::TransactionAware

      rescue_from ActiveRecord::RecordNotFound, with: :render_jsonapi_error
      rescue_from CannotDeleteWithAllocationsError, with: :render_unprocessable_error

      attr_reader :rendered

      def initialize(txn_id)
        @txn_id = txn_id
        @env = {}
      end

      def request
        @request ||= Struct.new(:headers, :env).new(
          { JsonapiToolbox::Controller::TransactionAware::TRANSACTION_HEADER => @txn_id },
          @env
        )
      end

      def render(**opts)
        @rendered = opts
      end

      # A custom app handler that opts into the transaction metadata via the
      # public reader, the way v1's real render_unprocessable_error does.
      def render_unprocessable_error(error)
        render json: {
          errors: [ { status: "422", title: error.message, detail: error.message } ],
          meta: transaction_error_meta
        }, status: :unprocessable_entity
      end
    end
  end

  let(:txn_id) { "277077c1-0000-4000-8000-000000000000" }
  let(:controller) { controller_class.new(txn_id) }

  # Stand in for the held transaction's thread surfacing a failed op back onto
  # the request thread, without booting the Manager or a real DB connection.
  def raise_op_error(original, rolled_back: false)
    allow(controller).to receive(:execute_on_held_transaction).and_raise(
      JsonapiToolbox::Transaction::Errors::OperationError.new(original, transaction_rolled_back: rolled_back)
    )
  end

  def run
    controller.send(:with_transaction_context) { :never_reached }
  end

  describe "handing off to app rescue_from handlers" do
    it "routes RecordNotFound to the app handler (404, not 500)" do
      raise_op_error(ActiveRecord::RecordNotFound.new("Couldn't find Departure with 'id'=999999999"))

      run

      expect(controller.rendered[:status]).to eq(:not_found)
      expect(controller.rendered[:json][:errors].first[:status]).to eq("404")
      expect(controller.rendered[:json][:errors].first[:detail]).to include("Couldn't find Departure")
    end

    it "routes an app-specific exception class to its declared handler (422 with a usable message)" do
      raise_op_error(
        CannotDeleteWithAllocationsError.new("can't delete hotel stay #1: it has 29 room allocation(s)")
      )

      run

      expect(controller.rendered[:status]).to eq(:unprocessable_entity)
      error = controller.rendered[:json][:errors].first
      expect(error[:status]).to eq("422")
      expect(error[:title]).to include("29 room allocation")
    end

    it "surfaces transaction metadata on the handed-off response" do
      raise_op_error(ActiveRecord::RecordNotFound.new("Couldn't find Departure"), rolled_back: false)

      run

      expect(controller.rendered[:json][:meta]).to eq(
        transaction_id: txn_id,
        transaction_rolled_back: false
      )
    end

    it "exposes transaction metadata via the public reader for custom handlers" do
      raise_op_error(CannotDeleteWithAllocationsError.new("conflict"))

      run

      expect(controller.rendered[:json][:meta]).to eq(
        transaction_id: txn_id,
        transaction_rolled_back: false
      )
    end
  end

  describe "fallback for unhandled errors" do
    it "renders a structured 500 (not a dev error page) when no app handler matches" do
      raise_op_error(RuntimeError.new("inner db thing"))

      run

      expect(controller.rendered[:status]).to eq(:internal_server_error)
      expect(controller.rendered[:json][:errors].first[:status]).to eq("500")
    end

    it "sets a title on the fallback body so json_api_client's title-only harvester finds a message" do
      raise_op_error(RuntimeError.new("inner db thing"))

      run

      error = controller.rendered[:json][:errors].first
      expect(error[:title]).to eq("inner db thing")
      expect(error[:detail]).to eq("inner db thing")
    end

    it "carries transaction metadata on the fallback body" do
      raise_op_error(RuntimeError.new("inner db thing"), rolled_back: true)

      run

      expect(controller.rendered[:json][:meta]).to eq(
        transaction_id: txn_id,
        transaction_rolled_back: true
      )
    end
  end

  describe "requests without a held transaction" do
    let(:controller) { controller_class.new(nil) }

    it "yields inline and lets errors propagate to the normal rescue chain" do
      expect do
        controller.send(:with_transaction_context) { raise ActiveRecord::RecordNotFound, "boom" }
      end.to raise_error(ActiveRecord::RecordNotFound)

      expect(controller.rendered).to be_nil
    end

    it "does not attach transaction metadata to stock error responses" do
      # No op error occurred, so request.env carries no transaction meta.
      controller.send(:render_jsonapi_error, ActiveRecord::RecordNotFound.new("Couldn't find Foo"))

      expect(controller.rendered[:json]).not_to have_key(:meta)
    end
  end
end
