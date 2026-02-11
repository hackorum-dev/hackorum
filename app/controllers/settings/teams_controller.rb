# frozen_string_literal: true

module Settings
  class TeamsController < Settings::BaseController
    before_action :set_team, only: [ :show, :update, :destroy ]
    before_action :require_team_accessible!, only: [ :show ]
    before_action :require_team_admin!, only: [ :update, :destroy ]
    skip_before_action :require_authentication, only: [ :index, :show ]

    def index
      @your_teams = user_signed_in? ? current_user.teams.includes(team_members: :user) : []
    end

    def show
      @team_members = @team.team_members.includes(:user)
      @is_member = user_signed_in? && @team.member?(current_user)
      @can_manage = user_signed_in? && @team.admin?(current_user)
      @can_invite = @can_manage
    end

    def create
      @team = Team.new(team_params)
      Team.transaction do
        @team.save!
        TeamMember.add_member(team: @team, user: current_user, role: :admin)
      end
      redirect_to settings_team_path(@team), notice: "Team created"
    rescue ActiveRecord::RecordInvalid => e
      redirect_to settings_teams_path, alert: e.record.errors.full_messages.to_sentence
    end

    def update
      if @team.update(team_update_params)
        redirect_to settings_team_path(@team), notice: "Team settings updated"
      else
        redirect_to settings_team_path(@team), alert: @team.errors.full_messages.to_sentence
      end
    end

    def destroy
      @team.destroy
      redirect_to settings_teams_path, notice: "Team deleted"
    end

    private

    def active_settings_section
      :teams
    end

    def set_team
      @team = Team.find(params[:id])
    end

    def team_params
      params.require(:team).permit(:name)
    end

    def team_update_params
      params.require(:team).permit(:visibility)
    end

    def require_team_admin!
      unless user_signed_in? && @team.admin?(current_user)
        redirect_to settings_team_path(@team), alert: "Admins only" and return
      end
    end

    def require_team_accessible!
      return if @team.accessible_to?(current_user)

      if user_signed_in?
        render_404
      else
        redirect_to new_session_path, alert: "Please sign in"
      end
    end
  end
end
