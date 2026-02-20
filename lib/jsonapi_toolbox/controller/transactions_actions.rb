# frozen_string_literal: true

module JsonapiToolbox
  module Controller
    # Server-side controller concern that provides full CRUD for held
    # transactions. Include this in your app's transactions controller:
    #
    #   class Api::Internal::TransactionsController < Api::Internal::BaseController
    #     include JsonapiToolbox::Controller::TransactionsActions
    #   end
    #
    # Then add the route:
    #
    #   resources :transactions, only: [:index, :show, :create, :update]
    #
    # Actions:
    #   POST   /transactions     — create a held transaction
    #   GET    /transactions     — list active transactions (monitoring)
    #   GET    /transactions/:id — show a single transaction
    #   PATCH  /transactions/:id — update state (commit or rollback)
    #
    module TransactionsActions
      extend ActiveSupport::Concern

      included do
        rescue_from JsonapiToolbox::Transaction::Errors::NotFoundError do |e|
          render json: {
            errors: [{ status: "404", detail: e.message }]
          }, status: :not_found
        end

        rescue_from JsonapiToolbox::Transaction::Errors::ExpiredError do |e|
          render json: {
            errors: [{ status: "410", detail: e.message }]
          }, status: :gone
        end

        rescue_from JsonapiToolbox::Transaction::Errors::ConcurrencyLimitError do |e|
          render json: {
            errors: [{ status: "429", detail: e.message }]
          }, status: :too_many_requests
        end
      end

      def index
        transactions = transaction_manager.active_transactions
        render_transaction(transactions)
      end

      def show
        txn = transaction_manager.find(params[:id])
        render_transaction(txn)
      end

      def create
        timeout = params.dig(:data, :attributes, :timeout_seconds)
        txn = transaction_manager.create(timeout_seconds: timeout)
        render_transaction(txn, status: :created)
      end

      def update
        requested_state = params.dig(:data, :attributes, :state)

        case requested_state
        when "committed"
          txn = transaction_manager.commit(params[:id])
        when "rolled_back"
          txn = transaction_manager.rollback(params[:id])
        else
          render json: {
            errors: [{
              status: "422",
              detail: "Invalid state transition: '#{requested_state}'. Must be 'committed' or 'rolled_back'."
            }]
          }, status: :unprocessable_entity
          return
        end

        render_transaction(txn)
      end

      private

      def transaction_manager
        JsonapiToolbox::Transaction::Manager.instance
      end

      def render_transaction(resource, options = {})
        render_jsonapi(resource, options.merge(serializer: JsonapiToolbox::Transaction::Serializer))
      end
    end
  end
end
