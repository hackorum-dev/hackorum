module Api
  module V1
    class SavedSearchSerializer < BaseSerializer
      def self.list(entries, context)
        default_id = context.user.default_saved_search_preference&.saved_search_id
        entries.map { |search, team| new(search, context, team: team, default_id: default_id).brief }
      end

      def brief
        team = extras[:team]
        {
          id: record.id,
          name: record.name,
          query: record.resolve_query(team: team),
          scope: record.scope,
          team: team && { id: team.id, name: team.name },
          default: record.id == extras[:default_id],
          topics_url: api_url("/topics?#{{ saved_search_id: record.id, team_id: team&.id }.compact.to_query}")
        }
      end
    end
  end
end
