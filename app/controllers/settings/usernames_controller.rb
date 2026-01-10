# frozen_string_literal: true

module Settings
  class UsernamesController < Settings::BaseController
    def update
      if current_user.update(username_params)
        redirect_to settings_profile_path, notice: "Username updated"
      else
        redirect_to settings_profile_path, alert: current_user.errors.full_messages.to_sentence
      end
    end

    private

    def username_params
      params.require(:user).permit(:username)
    end
  end
end
