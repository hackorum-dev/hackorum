# frozen_string_literal: true

class TeamMembersController < ApplicationController
  before_action :require_authentication
  before_action :set_team

  def create
    authorize_invite!
    return if performed?
    username = params[:username].to_s.strip
    user = User.find_by(username: username)
    return redirect_to @team, alert: "User not found" unless user

    TeamMember.add_member(team: @team, user:, role: :member)
    redirect_to @team, notice: "User added to team"
  rescue ActiveRecord::RecordInvalid => e
    redirect_to @team, alert: e.record.errors.full_messages.to_sentence
  end

  def destroy
    membership = @team.team_members.find(params[:id])

    if membership.user_id == current_user.id
      membership.destroy
      redirect_to teams_path, notice: "You left the team"
    else
      authorize_admin!
      return if performed?
      if @team.last_admin?(membership)
        redirect_to @team, alert: "Cannot remove the last admin"
      else
        membership.destroy
        redirect_to @team, notice: "Member removed"
      end
    end
  end

  private

  def set_team
    @team = Team.find(params[:team_id])
  end

  def authorize_invite!
    return if @team.admin?(current_user)
    redirect_to @team, alert: "Admins only"
    return
  end

  def authorize_admin!
    return if @team.admin?(current_user)
    redirect_to @team, alert: "Admins only"
    return
  end
end
