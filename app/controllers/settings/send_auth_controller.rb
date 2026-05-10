# frozen_string_literal: true

require "net/http"

module Settings
  class SendAuthController < Settings::BaseController
    before_action :require_admin

    def destroy
      identity = current_user.identities.find(params[:identity_id])
      revoke_remotely(identity)
      identity.update!(
        refresh_token: nil,
        access_token: nil,
        access_token_expires_at: nil,
        send_revoked_at: Time.current
      )
      redirect_to settings_account_path, notice: "Sending authorization revoked."
    end

    private

    def require_admin
      redirect_to settings_account_path, alert: "Not authorized." unless current_admin?
    end

    def revoke_remotely(identity)
      return if identity.refresh_token.blank?
      Net::HTTP.post_form(URI("https://oauth2.googleapis.com/revoke"),
                          token: identity.refresh_token)
    rescue StandardError => e
      Rails.logger.warn("Google revoke failed: #{e.class}: #{e.message}")
    end
  end
end
