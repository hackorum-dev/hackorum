# frozen_string_literal: true

module Settings
  class DeletionsController < Settings::BaseController
    def show
    end

    def create
      unless params[:confirmation].to_s.strip == "DELETE"
        return redirect_to settings_deletion_path, alert: "Please type DELETE to confirm."
      end

      if (teams = sole_admin_teams(current_user)).any?
        return redirect_to settings_deletion_path,
                           alert: "You are the only admin of #{teams.map(&:name).join(', ')}. Hand over admin or delete the team first."
      end

      perform_deletion!(current_user)
      reset_session
      redirect_to root_path, notice: "Your account has been deleted."
    end

    private

    def active_settings_section
      :deletion
    end

    def sole_admin_teams(user)
      user.team_members.role_admin.includes(:team).map(&:team).select { |t| t.team_members.role_admin.count == 1 }
    end

    def perform_deletion!(user)
      Identity.where(user_id: user.id).find_each(&:revoke_remotely)
      Identity.where(user_id: user.id).delete_all
      TeamMember.where(user_id: user.id).delete_all
      UserToken.where(user_id: user.id).delete_all
      user.aliases.update_all(user_id: nil, verified_at: nil)
      user.update!(password_digest: nil, deleted_at: Time.current, person_id: nil)
    end
  end
end
