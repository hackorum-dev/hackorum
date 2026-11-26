module ClassifyApi
  class BaseController < LineageApi::BaseController
    rescue_from ::Classify::Claims::Conflict do |e|
      render json: { error: e.message }, status: :conflict
    end

    rescue_from ::Classify::Claims::NotReady do |e|
      render json: { error: e.message }, status: :service_unavailable
    end
  end
end
