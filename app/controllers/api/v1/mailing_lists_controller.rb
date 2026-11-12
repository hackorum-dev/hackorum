module Api
  module V1
    class MailingListsController < BaseController
      def index
        render_page(MailingList.order(:display_name, :id).to_a, nil) do |list|
          MailingListSerializer.new(list, context).brief
        end
      end
    end
  end
end
