# frozen_string_literal: true

module Settings
  class PasswordsController < Settings::BaseController
    def show
    end

    def update_current
      user = current_user
      if user.password_digest.present?
        unless user.authenticate(params[:current_password])
          return redirect_to settings_password_path, alert: "Current password is incorrect"
        end
      end

      if user.update(password: params[:password], password_confirmation: params[:password_confirmation])
        redirect_to settings_password_path, notice: "Password updated."
      else
        redirect_to settings_password_path, alert: user.errors.full_messages.to_sentence
      end
    end

    private

    def active_settings_section
      :password
    end
  end
end
