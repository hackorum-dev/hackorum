module Api
  module V1
    class EventsController < BaseController
      FLAGS = { nil => false, "true" => true }.freeze

      rescue_from Api::EventFeed::Expired do
        render_error :cursor_expired, "This position is older than the feed keeps, start over from the list endpoints"
      end

      query_params :since, :types, :topic, :author, :list, :starred, :participating, :ci_runs, :limit, on: :index

      def index
        starred = flag(:starred)
        participating = flag(:participating)
        return require_token if (starred || participating) && !current_token

        feed = Api::EventFeed.new(
          since: string_param(:since), types: string_param(:types), topic: string_param(:topic),
          author: author_param, list: string_param(:list, max: TopicsController::LIST_LIMIT),
          starred: starred, participating: participating, user: current_user,
          ci_runs: string_param(:ci_runs), limit: params[:limit]
        )
        page = feed.page
        render_page(EventSerializer.brief_list(page.events, context), page.next_cursor, has_more: page.has_more)
      end

      private

      def flag(name)
        FLAGS.fetch(string_param(name)) { raise Api::InvalidParameter, "#{name} can only be true" }
      end
    end
  end
end
