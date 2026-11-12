module Api
  module V1
    class LineageController < BaseController
      include TopicLookup

      def show
        topic = find_topic!(params[:id])
        unless context.feature?(LineageSerializer::FEATURE)
          return render_error(:feature_required, "This needs an account with the #{LineageSerializer::FEATURE} feature")
        end

        run = LineageSerializer.current_run(topic.id) || raise(ActiveRecord::RecordNotFound)
        render json: LineageSerializer.new(run, context).full
      end
    end
  end
end
