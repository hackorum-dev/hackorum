module Api
  module V1
    class LineageController < BaseController
      include TopicLookup

      def show
        topic = find_topic!(params[:id])
        run = LineageSerializer.current_run(topic.id) || raise(ActiveRecord::RecordNotFound)
        render json: LineageSerializer.new(run, context).full
      end
    end
  end
end
