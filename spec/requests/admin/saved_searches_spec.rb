# frozen_string_literal: true

require 'rails_helper'

RSpec.describe "Admin::SavedSearches", type: :request do
  def sign_in(email:, password: "secret")
    post session_path, params: { email: email, password: password }
    expect(response).to redirect_to(root_path)
  end

  def attach_verified_alias(user, email:)
    al = create(:alias, user: user, email: email)
    user.person.update!(default_alias_id: al.id) if user.person&.default_alias_id.nil?
    Alias.by_email(email).update_all(verified_at: Time.current)
    al
  end

  let!(:admin) { create(:user, password: "secret", password_confirmation: "secret", admin: true, username: "admin_user") }
  let!(:regular_user) { create(:user, password: "secret", password_confirmation: "secret", admin: false, username: "regular_user") }

  before do
    attach_verified_alias(admin, email: "admin@example.com")
    attach_verified_alias(regular_user, email: "regular@example.com")
  end

  describe "access control" do
    it "redirects unauthenticated users" do
      get admin_saved_searches_path
      expect(response).to redirect_to(root_path)
    end

    it "redirects non-admin users" do
      sign_in(email: "regular@example.com")
      get admin_saved_searches_path
      expect(response).to redirect_to(root_path)
    end
  end

  describe "GET /admin/saved_searches" do
    before { sign_in(email: "admin@example.com") }

    it "lists global searches by default" do
      create(:saved_search, name: "Global Inbox", query: "in:inbox", scope: "global")
      create(:saved_search, name: "My Unread Items", query: "unread:true", scope: "user")

      get admin_saved_searches_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Global Inbox")
      expect(response.body).not_to include("My Unread Items")
    end

    it "lists user templates with tab=user_templates" do
      create(:saved_search, name: "User Template", query: "unread:true", scope: "user", user: nil)
      create(:saved_search, name: "Global Inbox", query: "in:inbox", scope: "global")

      get admin_saved_searches_path(tab: "user_templates")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("User Template")
      expect(response.body).not_to include("Global Inbox")
    end

    it "lists team templates with tab=team_templates" do
      create(:saved_search, name: "Team Template", query: "team:true", scope: "team", team: nil)
      create(:saved_search, name: "Global Inbox", query: "in:inbox", scope: "global")

      get admin_saved_searches_path(tab: "team_templates")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Team Template")
      expect(response.body).not_to include("Global Inbox")
    end
  end

  describe "POST /admin/saved_searches" do
    before { sign_in(email: "admin@example.com") }

    it "creates a global saved search" do
      expect {
        post admin_saved_searches_path, params: { saved_search: { name: "New Global", query: "starred:true", scope: "global", position: 1 } }
      }.to change { SavedSearch.scope_global.count }.by(1)

      expect(response).to redirect_to(admin_saved_searches_path(tab: "global"))
    end

    it "creates a user template (system_defined)" do
      expect {
        post admin_saved_searches_path, params: { saved_search: { name: "New User Template", query: "unread:true", scope: "user", position: 0 } }
      }.to change { SavedSearch.user_templates.count }.by(1)

      search = SavedSearch.last
      expect(search.system_defined?).to be true
      expect(response).to redirect_to(admin_saved_searches_path(tab: "user_templates"))
    end

    it "creates a team template (system_defined)" do
      expect {
        post admin_saved_searches_path, params: { saved_search: { name: "New Team Template", query: "team:true", scope: "team", position: 0 } }
      }.to change { SavedSearch.team_templates.count }.by(1)

      search = SavedSearch.last
      expect(search.system_defined?).to be true
      expect(response).to redirect_to(admin_saved_searches_path(tab: "team_templates"))
    end

    it "re-renders form on validation error" do
      post admin_saved_searches_path, params: { saved_search: { name: "", query: "", scope: "global" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("New Saved Search")
    end
  end

  describe "PATCH /admin/saved_searches/:id" do
    before { sign_in(email: "admin@example.com") }

    it "updates a saved search" do
      search = create(:saved_search, name: "Old Name", query: "in:inbox", scope: "global")

      patch admin_saved_search_path(search), params: { saved_search: { name: "New Name", query: "in:archive" } }
      expect(response).to redirect_to(admin_saved_searches_path(tab: "global"))

      search.reload
      expect(search.name).to eq("New Name")
      expect(search.query).to eq("in:archive")
    end
  end

  describe "DELETE /admin/saved_searches/:id" do
    before { sign_in(email: "admin@example.com") }

    it "deletes a saved search" do
      search = create(:saved_search, name: "Doomed", query: "in:trash", scope: "global")

      expect {
        delete admin_saved_search_path(search)
      }.to change { SavedSearch.count }.by(-1)

      expect(response).to redirect_to(admin_saved_searches_path(tab: "global"))
    end
  end
end
