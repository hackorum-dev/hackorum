class TeamsProfileController < ApplicationController
  include TeamProfileScope
  include ProfileActivity
  include ProfilePeriodActions

  def show
    @active_tab = params[:tab] == "commits" ? :commits : :messages
    @profile_stats = ProfileStats.new(@member_person_ids, sources: commit_credit_sources)
    @members = @team.team_members.includes(user: { person: :default_alias }).order(:role, :created_at)
    load_activity_data(period: default_activity_period)
  end

  private

  def default_activity_period
    ProfilePeriod.recent(30.days)
  end
end
