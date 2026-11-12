module Api
  module V1
    class TopicsController < BaseController
      include TopicLookup

      LIST_LIMIT = 100

      rescue_from Api::TopicList::InvalidQuery do |e|
        render_error :invalid_query, e.message
      end

      query_params :q, :saved_search_id, :team_id, :list, :author, :sort, paged: true, on: :index
      cursor_per_caller on: :index

      def index
        saved = saved_search_query
        list = Api::TopicList.new(q: saved || string_param(:q), list: string_param(:list, max: LIST_LIMIT),
                                  author: author_param, sort: string_param(:sort), user: current_user)
        topics, next_cursor = list.run do
          paginate(list.relation, columns: list.columns, not_null: list.not_null) do |page|
            page.preload(TopicSerializer::PRELOAD)
          end
        end

        extra = saved ? { query: saved } : {}
        render_page(TopicSerializer.brief_list(topics, context), next_cursor, warnings: list.warnings, **extra)
      end

      def show
        render json: TopicSerializer.new(find_topic!(params[:id], preload: TopicSerializer::PRELOAD), context).full
      end

      private

      # resolved as the site's search does: what the caller cannot see is a 404
      def saved_search_query
        id = id_param(:saved_search_id)
        team_id = id_param(:team_id)
        raise Api::InvalidParameter, "team_id needs saved_search_id" if team_id && !id
        return unless id
        raise Api::InvalidParameter, "saved_search_id cannot be combined with q" if params.key?(:q)

        search = SavedSearch.visible_to(current_user).find_by(id: id) || raise(ActiveRecord::RecordNotFound)
        return search.resolve_query unless search.scope_team?

        query = search.resolve_query(team: team_id ? accessible_team(team_id) : search.team)
        raise Api::InvalidParameter, "this saved search is a team template, team_id is needed" if query.include?("{{team_name}}")

        query
      end

      def accessible_team(id)
        team = Team.find_by(id: id)
        raise ActiveRecord::RecordNotFound unless team&.accessible_to?(current_user)

        team
      end

      def id_param(name)
        value = string_param(name)
        return if value.nil?
        raise Api::InvalidParameter, "#{name} must be a number" unless value.match?(/\A\d+\z/)

        value
      end
    end
  end
end
