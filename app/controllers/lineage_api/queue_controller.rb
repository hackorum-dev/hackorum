module LineageApi
  class QueueController < BaseController
    def show
      render json: ::Lineage::Queue.counts
    end
  end
end
