# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Settings::SendAuth", type: :request do
  let(:user) { create(:user, admin: true) }
  let!(:identity) {
    create(:identity, user: user, refresh_token: "r", access_token: "a",
           access_token_expires_at: 1.hour.from_now,
           send_authorized_at: 1.hour.ago)
  }

  before { sign_in_as(user) }

  describe "DELETE /settings/send_auth/:identity_id" do
    it "revokes the identity locally" do
      allow(Net::HTTP).to receive(:post_form).and_return(double(code: "200", body: ""))
      delete settings_send_auth_path(identity_id: identity.id)
      identity.reload
      expect(identity.refresh_token).to be_nil
      expect(identity.access_token).to be_nil
      expect(identity.access_token_expires_at).to be_nil
      expect(identity.send_revoked_at).not_to be_nil
      expect(response).to redirect_to(settings_account_path)
    end

    it "revokes locally even when google revoke fails" do
      allow(Net::HTTP).to receive(:post_form).and_raise(SocketError, "down")
      delete settings_send_auth_path(identity_id: identity.id)
      expect(identity.reload.refresh_token).to be_nil
      expect(identity.send_revoked_at).not_to be_nil
    end

    it "requires authentication" do
      allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(nil)
      allow_any_instance_of(ApplicationController).to receive(:user_signed_in?).and_return(false)
      delete settings_send_auth_path(identity_id: identity.id)
      expect(response).to have_http_status(:found)
    end

    it "forbids revoking another user's identity" do
      other_user = create(:user)
      other_identity = create(:identity, user: other_user, refresh_token: "x",
                              send_authorized_at: 1.hour.ago)
      delete settings_send_auth_path(identity_id: other_identity.id)
      expect(other_identity.reload.refresh_token).to eq("x")
    end

    it "forbids non-admin users from revoking" do
      non_admin = create(:user)
      sign_in_as(non_admin)
      non_admin_identity = create(:identity, user: non_admin, refresh_token: "y",
                                  send_authorized_at: 1.hour.ago)
      delete settings_send_auth_path(identity_id: non_admin_identity.id)
      expect(non_admin_identity.reload.refresh_token).to eq("y")
      expect(response).to redirect_to(settings_account_path)
    end
  end
end
