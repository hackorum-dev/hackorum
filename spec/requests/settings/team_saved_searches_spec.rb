# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Settings::Teams::SavedSearches", type: :request do
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
  let!(:team_admin) { create(:user, password: "secret", password_confirmation: "secret") }
  let!(:team_member) { create(:user, password: "secret", password_confirmation: "secret") }
  let!(:non_member) { create(:user, password: "secret", password_confirmation: "secret") }

  before do
    create(:team_member, team: team, user: team_admin, role: "admin")
    create(:team_member, team: team, user: team_member, role: "member")
    attach_verified_alias(team_admin, email: "admin@example.com")
    attach_verified_alias(team_member, email: "member@example.com")
    attach_verified_alias(non_member, email: "nonmember@example.com")
  end

  describe "GET /settings/teams/:team_id/saved_searches" do
    let!(:team_search) { create(:saved_search, name: "Team Bug Triage", query: "label:bug", scope: "team", team: team) }

    it "allows team members to view saved searches" do
      sign_in(email: "member@example.com")

      get settings_team_saved_searches_path(team)
      expect(response).to have_http_status(:success)
      expect(response.body).to include("Team Bug Triage")
    end

    it "returns 404 for non-members" do
      sign_in(email: "nonmember@example.com")

      get settings_team_saved_searches_path(team)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /settings/teams/:team_id/saved_searches" do
    it "allows team admins to create a saved search" do
      sign_in(email: "admin@example.com")

      expect {
        post settings_team_saved_searches_path(team), params: { saved_search: { name: "New Search", query: "status:open" } }
      }.to change(SavedSearch, :count).by(1)

      search = SavedSearch.last
      expect(search.scope).to eq("team")
      expect(search.team_id).to eq(team.id)
      expect(response).to redirect_to(settings_team_saved_searches_path(team))
    end

    it "blocks non-admin members" do
      sign_in(email: "member@example.com")

      expect {
        post settings_team_saved_searches_path(team), params: { saved_search: { name: "Blocked Search", query: "status:open" } }
      }.not_to change(SavedSearch, :count)

      expect(response).to redirect_to(settings_team_saved_searches_path(team))
    end
  end

  describe "DELETE /settings/teams/:team_id/saved_searches/:id" do
    let!(:team_search) { create(:saved_search, name: "Deletable Search", query: "label:stale", scope: "team", team: team) }

    it "allows team admins to delete a saved search" do
      sign_in(email: "admin@example.com")

      expect {
        delete settings_team_saved_search_path(team, team_search)
      }.to change(SavedSearch, :count).by(-1)

      expect(response).to redirect_to(settings_team_saved_searches_path(team))
    end

    it "blocks non-admin members" do
      sign_in(email: "member@example.com")

      expect {
        delete settings_team_saved_search_path(team, team_search)
      }.not_to change(SavedSearch, :count)

      expect(response).to redirect_to(settings_team_saved_searches_path(team))
      expect(SavedSearch.exists?(team_search.id)).to be(true)
    end
  end
end
