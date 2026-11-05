require "rails_helper"

RSpec.describe "Admin::UserFeatures", type: :request do
  let(:admin) { create(:user, admin: true) }
  let(:target) { create(:user) }

  before { sign_in_as(admin) }

  describe "GET /admin/users/:user_id/features" do
    it "lists all features with current enrollment state" do
      create(:user_feature, user: target, feature: "email_sending")
      get admin_user_features_path(target)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Email sending")
    end

    it "rejects non-admins" do
      sign_in_as(create(:user))
      get admin_user_features_path(target)
      expect(response).to have_http_status(:found)
    end
  end

  describe "POST /admin/users/:user_id/features" do
    it "enrolls the user in the feature" do
      post admin_user_features_path(target), params: { feature: "email_sending" }
      expect(target.user_features.where(feature: "email_sending")).to exist
      expect(response).to redirect_to(admin_user_features_path(target))
    end

    it "ignores duplicates without crashing" do
      create(:user_feature, user: target, feature: "email_sending")
      post admin_user_features_path(target), params: { feature: "email_sending" }
      expect(target.user_features.where(feature: "email_sending").count).to eq(1)
    end

    it "rejects unknown features" do
      post admin_user_features_path(target), params: { feature: "bogus" }
      expect(target.user_features).to be_empty
      expect(flash[:alert]).to be_present
    end
  end

  describe "DELETE /admin/users/:user_id/features/:name" do
    it "removes the enrollment" do
      create(:user_feature, user: target, feature: "email_sending")
      delete admin_user_feature_path(target, "email_sending")
      expect(target.user_features.where(feature: "email_sending")).not_to exist
    end
  end

  describe "team-derived features" do
    let(:team) { create(:team, name: "reviewers") }

    before do
      create(:team_member, team: team, user: target)
      create(:team_feature, team: team, feature: "email_sending")
    end

    it "shows the team source" do
      get admin_user_features_path(target)
      expect(response.body).to include("via reviewers")
      expect(response.body).to include(admin_user_features_path(target, feature: :email_sending))
    end

    it "shows both direct and team source" do
      create(:user_feature, user: target, feature: "email_sending")
      get admin_user_features_path(target)
      expect(response.body).to include("Enabled")
      expect(response.body).to include("via reviewers")
      expect(response.body).to include(admin_user_feature_path(target, :email_sending))
    end
  end
end
