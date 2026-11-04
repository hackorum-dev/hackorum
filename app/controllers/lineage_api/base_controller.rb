module LineageApi
  class BaseController < ActionController::API
    before_action :authenticate!

    rescue_from ActiveRecord::RecordNotFound do
      head :not_found
    end

    rescue_from ::Lineage::Claims::Conflict do |e|
      render json: { error: e.message }, status: :conflict
    end

    rescue_from ActionController::ParameterMissing do |e|
      render json: { error: e.message }, status: :bad_request
    end

    private

    def authenticate!
      token = ENV["LINEAGE_API_TOKEN"].presence
      return head :not_found unless token
      given = request.authorization.to_s.delete_prefix("Bearer ").strip
      head :unauthorized unless given.present? && ActiveSupport::SecurityUtils.secure_compare(given, token)
    end
  end
end
