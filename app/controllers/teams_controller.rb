# frozen_string_literal: true

class TeamsController < ApplicationController
  before_action :require_authentication, except: [:show, :index]
  before_action :set_team, only: [:show, :destroy]
  before_action :require_team_member!, only: [:show]
  before_action :require_team_admin!, only: [:destroy]

  def index
    @your_teams = user_signed_in? ? current_user.teams.includes(team_members: :user) : []
    @all_teams = Team.includes(team_members: :user).order(:name)
  end

  def show
    @team_members = @team.team_members.includes(:user)
    @can_manage = user_signed_in? && @team.admin?(current_user)
    @can_invite = user_signed_in? && (@team.member?(current_user) || @team.admin?(current_user))
  end

  def create
    @team = Team.new(team_params)
    Team.transaction do
      @team.save!
      TeamMember.add_member(team: @team, user: current_user, role: :admin)
    end
    redirect_to @team, notice: "Team created"
  rescue ActiveRecord::RecordInvalid => e
    redirect_to teams_path, alert: e.record.errors.full_messages.to_sentence
  end

  def destroy
    @team.destroy
    redirect_to teams_path, notice: "Team deleted"
  end

  private

  def set_team
    @team = Team.find(params[:id])
  end

  def team_params
    params.require(:team).permit(:name)
  end

  def require_team_admin!
    unless user_signed_in? && @team.admin?(current_user)
      redirect_to @team, alert: "Admins only" and return
    end
  end

  def require_team_member!
    unless user_signed_in?
      redirect_to new_session_path, alert: "Please sign in"
      return
    end

    render_404 unless @team.member?(current_user)
  end
end
