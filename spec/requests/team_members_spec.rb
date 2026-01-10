require "rails_helper"

RSpec.describe "TeamMembers", type: :request do
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

  let!(:team) { create(:team) }
  let!(:admin) { create(:user, password: "secret", password_confirmation: "secret") }
  let!(:member) { create(:user, password: "secret", password_confirmation: "secret") }
  let!(:invitee) { create(:user, username: "invitee") }

  before do
    create(:team_member, team: team, user: admin, role: "admin")
    create(:team_member, team: team, user: member, role: "member")
  end

  describe "POST /teams/:team_id/team_members" do
    it "blocks non-admins from adding members" do
      attach_verified_alias(member, email: "member@example.com")
      sign_in(email: "member@example.com")

      expect {
        post settings_team_team_members_path(team), params: { username: "invitee" }
      }.not_to change(TeamMember, :count)
      expect(response).to redirect_to(settings_team_path(team))
    end

    it "allows admins to add members" do
      attach_verified_alias(admin, email: "admin@example.com")
      sign_in(email: "admin@example.com")

      expect {
        post settings_team_team_members_path(team), params: { username: "invitee" }
      }.to change(TeamMember, :count).by(1)
      expect(response).to redirect_to(settings_team_path(team))
    end
  end
end
