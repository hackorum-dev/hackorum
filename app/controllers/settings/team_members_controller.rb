# frozen_string_literal: true

module Settings
  class TeamMembersController < Settings::BaseController
    before_action :set_team

    def create
      authorize_invite!
      return if performed?
      username = params[:username].to_s.strip
      user = User.find_by(username: username)
      return redirect_to settings_team_path(@team), alert: "User not found" unless user

      TeamMember.add_member(team: @team, user:, role: :member)
      redirect_to settings_team_path(@team), notice: "User added to team"
    rescue ActiveRecord::RecordInvalid => e
      redirect_to settings_team_path(@team), alert: e.record.errors.full_messages.to_sentence
    end

    def update
      authorize_admin!
      return if performed?

      membership = @team.team_members.find(params[:id])
      new_role = params[:role]

      # Prevent admin from removing their own admin status
      if membership.user_id == current_user.id && new_role == "member"
        return redirect_to settings_team_path(@team), alert: "You cannot remove your own admin status"
      end

      # Prevent removing the last admin
      if membership.admin? && new_role == "member" && @team.last_admin?(membership)
        return redirect_to settings_team_path(@team), alert: "Cannot demote the last admin"
      end

      membership.update!(role: new_role)
      redirect_to settings_team_path(@team), notice: "Member role updated"
    rescue ActiveRecord::RecordInvalid => e
      redirect_to settings_team_path(@team), alert: e.record.errors.full_messages.to_sentence
    end

    def destroy
      membership = @team.team_members.find(params[:id])

      if membership.user_id == current_user.id
        if @team.last_admin?(membership)
          redirect_to settings_team_path(@team), alert: "You cannot leave as the last admin"
        else
          membership.destroy
          redirect_to settings_teams_path, notice: "You left the team"
        end
      else
        authorize_admin!
        return if performed?
        if @team.last_admin?(membership)
          redirect_to settings_team_path(@team), alert: "Cannot remove the last admin"
        else
          membership.destroy
          redirect_to settings_team_path(@team), notice: "Member removed"
        end
      end
    end

    private

    def set_team
      @team = Team.find(params[:team_id])
    end

    def authorize_invite!
      return if @team.admin?(current_user)
      redirect_to settings_team_path(@team), alert: "Admins only"
      nil
    end

    def authorize_admin!
      return if @team.admin?(current_user)
      redirect_to settings_team_path(@team), alert: "Admins only"
      nil
    end
  end
end
