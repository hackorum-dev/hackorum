require "rails_helper"

RSpec.describe "Teams", type: :request do
  def sign_in(email:, password: "secret")
    post session_path, params: { email: email, password: password }
    expect(response).to redirect_to(root_path)
  end

  def attach_verified_alias(user, email:, primary: true)
    al = create(:alias, user: user, email: email)
    if primary && user.person&.default_alias_id.nil?
      user.person.update!(default_alias_id: al.id)
    end
    Alias.by_email(email).update_all(verified_at: Time.current)
    al
  end

  describe "GET /teams/:id" do
    let!(:team) { create(:team) }
    let!(:member) { create(:user, password: "secret", password_confirmation: "secret") }
    let!(:non_member) { create(:user, password: "secret", password_confirmation: "secret") }

    before do
      create(:team_member, team: team, user: member)
    end

    it "redirects guests to sign in" do
      get settings_team_path(team)
      expect(response).to redirect_to(new_session_path)
    end

    it "returns 404 for signed-in non-members" do
      attach_verified_alias(non_member, email: "non-member@example.com")
      sign_in(email: "non-member@example.com")

      get settings_team_path(team)
      expect(response).to have_http_status(:not_found)
    end

    it "allows signed-in team members" do
      attach_verified_alias(member, email: "member@example.com")
      sign_in(email: "member@example.com")

      get settings_team_path(team)
      expect(response).to have_http_status(:success)
    end
  end

  describe "DELETE /teams/:id" do
    let!(:team) { create(:team) }
    let!(:admin) { create(:user, password: "secret", password_confirmation: "secret") }
    let!(:member) { create(:user, password: "secret", password_confirmation: "secret") }

    before do
      create(:team_member, team: team, user: admin, role: "admin")
      create(:team_member, team: team, user: member, role: "member")
    end

    it "blocks non-admins from deleting teams" do
      attach_verified_alias(member, email: "member@example.com")
      sign_in(email: "member@example.com")

      delete settings_team_path(team)
      expect(response).to redirect_to(settings_team_path(team))
      expect(Team.exists?(team.id)).to be(true)
    end

    it "allows admins to delete teams" do
      attach_verified_alias(admin, email: "admin@example.com")
      sign_in(email: "admin@example.com")

      expect {
        delete settings_team_path(team)
      }.to change(Team, :count).by(-1)
    end
  end
end
