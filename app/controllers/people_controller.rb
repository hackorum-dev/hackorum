class PeopleController < ApplicationController
  include PersonProfileScope
  include ProfileActivity
  include ProfilePeriodActions

  def show
    @active_tab = params[:tab] == "commits" ? :commits : :messages
    @profile_stats = ProfileStats.new(@person.id, sources: commit_credit_sources)
    @teams = load_visible_teams
    load_activity_data(period: default_activity_period)
  end

  private

  def default_activity_period
    ProfilePeriod.recent(30.days)
  end

  def load_visible_teams
    user = @person.user
    return [] unless user

    all_teams = user.teams.includes(:team_members)

    all_teams.select do |team|
      if team.visibility_open? || team.visibility_visible?
        true
      elsif current_user && current_user.id == user.id
        true
      elsif current_user && team.member?(current_user)
        true
      else
        false
      end
    end
  end
end
