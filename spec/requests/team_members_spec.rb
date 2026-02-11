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

  describe "PATCH /teams/:team_id/team_members/:id" do
    it "blocks non-admins from changing roles" do
      attach_verified_alias(member, email: "member@example.com")
      sign_in(email: "member@example.com")

      member_record = team.team_members.find_by(user: member)
      patch settings_team_team_member_path(team, member_record), params: { role: "admin" }

      expect(response).to redirect_to(settings_team_path(team))
      expect(member_record.reload.role).to eq("member")
    end

    it "allows admins to promote members to admin" do
      attach_verified_alias(admin, email: "admin@example.com")
      sign_in(email: "admin@example.com")

      member_record = team.team_members.find_by(user: member)
      patch settings_team_team_member_path(team, member_record), params: { role: "admin" }

      expect(response).to redirect_to(settings_team_path(team))
      expect(member_record.reload.role).to eq("admin")
    end

    it "allows admins to demote other admins to members" do
      attach_verified_alias(admin, email: "admin@example.com")
      sign_in(email: "admin@example.com")

      other_admin = create(:user, password: "secret", password_confirmation: "secret")
      other_admin_record = create(:team_member, team: team, user: other_admin, role: "admin")

      patch settings_team_team_member_path(team, other_admin_record), params: { role: "member" }

      expect(response).to redirect_to(settings_team_path(team))
      expect(other_admin_record.reload.role).to eq("member")
    end

    it "prevents admin from removing their own admin status" do
      attach_verified_alias(admin, email: "admin@example.com")
      sign_in(email: "admin@example.com")

      admin_record = team.team_members.find_by(user: admin)
      patch settings_team_team_member_path(team, admin_record), params: { role: "member" }

      expect(response).to redirect_to(settings_team_path(team))
      expect(flash[:alert]).to include("cannot remove your own admin status")
      expect(admin_record.reload.role).to eq("admin")
    end

    it "prevents demoting the last admin when there are two admins and one tries to demote the other after becoming the only admin" do
      # Create a second admin who will try to demote the first
      other_admin = create(:user, password: "secret", password_confirmation: "secret")
      attach_verified_alias(other_admin, email: "other_admin@example.com")
      create(:team_member, team: team, user: other_admin, role: "admin")

      sign_in(email: "other_admin@example.com")

      # Demote the first admin - this should work since there are 2 admins
      admin_record = team.team_members.find_by(user: admin)
      patch settings_team_team_member_path(team, admin_record), params: { role: "member" }
      expect(admin_record.reload.role).to eq("member")

      # Now other_admin is the only admin
      # Try to demote them using the first admin (now just a member, so should fail authorization)
      attach_verified_alias(admin, email: "admin@example.com")
      sign_in(email: "admin@example.com")

      other_admin_record = team.team_members.find_by(user: other_admin)
      patch settings_team_team_member_path(team, other_admin_record), params: { role: "member" }

      expect(response).to redirect_to(settings_team_path(team))
      expect(flash[:alert]).to eq("Admins only")
      expect(other_admin_record.reload.role).to eq("admin")
    end
  end
end
