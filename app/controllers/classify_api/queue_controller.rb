module ClassifyApi
  class QueueController < BaseController
    def show
      render json: ::Classify::Queue.counts
    end
  end
end
