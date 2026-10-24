# frozen_string_literal: true

module Settings
  class SendAuthController < Settings::BaseController
    before_action :require_email_sending_feature

    def destroy
      identity = current_user.identities.find(params[:identity_id])
      identity.revoke_remotely
      identity.update!(
        refresh_token: nil,
        access_token: nil,
        access_token_expires_at: nil,
        send_revoked_at: Time.current
      )
      redirect_to settings_account_path, notice: "Sending authorization revoked."
    end

    private

    def require_email_sending_feature
      redirect_to settings_account_path, alert: "Not authorized." unless current_user&.has_feature?(:email_sending)
    end
  end
end
