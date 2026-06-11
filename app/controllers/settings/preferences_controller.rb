# frozen_string_literal: true

module Settings
  class PreferencesController < Settings::BaseController
    def update
      if current_user.update(preferences_params)
        redirect_to settings_profile_path, notice: "Preferences updated"
      else
        redirect_to settings_profile_path, alert: current_user.errors.full_messages.to_sentence
      end
    end

    private

    def preferences_params
      params.require(:user).permit(:mention_restriction, :open_threads_at_first_unread, :collapse_read_messages, :collapse_quotes)
    end
  end
end
