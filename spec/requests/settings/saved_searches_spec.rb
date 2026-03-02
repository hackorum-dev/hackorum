require "rails_helper"

RSpec.describe "Settings::SavedSearches", type: :request do
  def sign_in(user)
    al = create(:alias, user: user, email: "login-#{user.id}@example.com")
    user.person.update!(default_alias_id: al.id) if user.person.default_alias_id.nil?
    Alias.by_email(al.email).update_all(verified_at: Time.current)
    user.update!(password: "secret", password_confirmation: "secret") unless user.password_digest.present?
    post session_path, params: { email: al.email, password: "secret" }
  end

  describe "access control" do
    it "redirects guests to sign in" do
      get settings_saved_searches_path
      expect(response).to redirect_to(new_session_path)
    end
  end

  describe "GET /settings/saved_searches" do
    it "lists the current user's saved searches" do
      user = create(:user)
      search = create(:saved_search, name: "My Search", query: "is:open", scope: "user", user: user)
      sign_in(user)

      get settings_saved_searches_path
      expect(response).to have_http_status(:success)
      expect(response.body).to include("My Search")
    end

    it "does not list other users' saved searches" do
      user = create(:user)
      other = create(:user)
      create(:saved_search, name: "Other Search", query: "is:closed", scope: "user", user: other)
      sign_in(user)

      get settings_saved_searches_path
      expect(response).to have_http_status(:success)
      expect(response.body).not_to include("Other Search")
    end

    it "lists system-defined user templates" do
      user = create(:user)
      create(:saved_search, name: "Template Search", query: "is:unread", scope: "user", user: nil)
      sign_in(user)

      get settings_saved_searches_path
      expect(response).to have_http_status(:success)
      expect(response.body).to include("Template Search")
    end

    it "lists global searches with hide/show controls" do
      user = create(:user)
      create(:saved_search, name: "Global Inbox", query: "in:inbox", scope: "global")
      sign_in(user)

      get settings_saved_searches_path
      expect(response).to have_http_status(:success)
      expect(response.body).to include("Global Inbox")
      expect(response.body).to include("Global Searches")
    end
  end

  describe "POST /settings/saved_searches" do
    it "creates a user-scoped search owned by the current user" do
      user = create(:user)
      sign_in(user)

      expect {
        post settings_saved_searches_path, params: { saved_search: { name: "New Search", query: "author:me" } }
      }.to change(SavedSearch, :count).by(1)

      search = SavedSearch.last
      expect(search.user_id).to eq(user.id)
      expect(search.scope).to eq("user")
      expect(search.name).to eq("New Search")
      expect(search.query).to eq("author:me")
    end

    it "forces scope to user regardless of params" do
      user = create(:user)
      sign_in(user)

      post settings_saved_searches_path, params: { saved_search: { name: "Sneaky", query: "is:open", scope: "global" } }

      search = SavedSearch.last
      expect(search.scope).to eq("user")
    end
  end

  describe "PATCH /settings/saved_searches/:id" do
    it "updates the current user's saved search" do
      user = create(:user)
      search = create(:saved_search, name: "Old Name", query: "is:open", scope: "user", user: user)
      sign_in(user)

      patch settings_saved_search_path(search), params: { saved_search: { name: "New Name" } }
      expect(response).to redirect_to(settings_saved_searches_path)
      expect(search.reload.name).to eq("New Name")
    end

    it "cannot update another user's saved search" do
      user = create(:user)
      other = create(:user)
      search = create(:saved_search, name: "Other", query: "is:open", scope: "user", user: other)
      sign_in(user)

      patch settings_saved_search_path(search), params: { saved_search: { name: "Hijacked" } }
      expect(response).to have_http_status(:not_found)
      expect(search.reload.name).to eq("Other")
    end
  end

  describe "DELETE /settings/saved_searches/:id" do
    it "deletes the current user's saved search" do
      user = create(:user)
      search = create(:saved_search, name: "Doomed", query: "is:open", scope: "user", user: user)
      sign_in(user)

      expect {
        delete settings_saved_search_path(search)
      }.to change(SavedSearch, :count).by(-1)
    end

    it "cannot delete another user's saved search" do
      user = create(:user)
      other = create(:user)
      search = create(:saved_search, name: "Protected", query: "is:open", scope: "user", user: other)
      sign_in(user)

      delete settings_saved_search_path(search)
      expect(response).to have_http_status(:not_found)
      expect(SavedSearch.exists?(search.id)).to be true
    end
  end
end
