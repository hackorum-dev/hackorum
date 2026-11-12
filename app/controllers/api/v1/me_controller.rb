module Api
  module V1
    class MeController < BaseController
      before_action :require_token

      def show
        render json: MeSerializer.new(context).full
      end
    end
  end
end
