module Api
  # The saved searches the sidebar offers a user, in its order, as
  # [ search, team ] pairs: a team template comes once per team.
  class SavedSearchList
    def initialize(user)
      @user = user
    end

    def entries
      searches = SavedSearch.visible_to_unhidden(@user).order(:position, :name, :id).to_a
      global = searches.select(&:scope_global?)
      personal = searches.select(&:scope_user?).partition { |search| search.user_id.nil? }.flatten
      (global + personal).map { |search| [ search, nil ] } + team_entries(searches.select(&:scope_team?))
    end

    private

    def team_entries(searches)
      templates, owned = searches.partition { |search| search.team_id.nil? }
      owned = owned.group_by(&:team_id)
      @user.teams.sort_by(&:id).flat_map do |team|
        (owned.fetch(team.id, []) + templates).map { |search| [ search, team ] }
      end
    end
  end
end
