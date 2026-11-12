module Api
  module V1
    class PatchsetsController < BaseController
      include TopicLookup

      query_params paged: true, on: :index

      def index
        topic = find_topic!(params[:id])
        messages, next_cursor = paginate(topic.messages.where(is_patch_submission: true),
                                         columns: %w[messages.created_at messages.id]) do |page|
          PatchsetSerializer.load(page)
        end
        render_page(PatchsetSerializer.brief_list(messages, context), next_cursor)
      end
    end
  end
end
