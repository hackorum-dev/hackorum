# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Settings::SavedSearchPreferences", type: :request do
  def sign_in(user)
    al = create(:alias, user: user, email: "login-#{user.id}@example.com")
    user.person.update!(default_alias_id: al.id) if user.person.default_alias_id.nil?
    Alias.by_email(al.email).update_all(verified_at: Time.current)
    user.update!(password: "secret", password_confirmation: "secret") unless user.password_digest.present?
    post session_path, params: { email: al.email, password: "secret" }
  end

  describe "POST /settings/saved_search_preferences" do
    it "hides a saved search" do
      user = create(:user)
      saved_search = create(:saved_search)
      sign_in(user)

      expect {
        post settings_saved_search_preferences_path, params: { saved_search_id: saved_search.id, hidden: true }
      }.to change(SavedSearchPreference, :count).by(1)

      pref = SavedSearchPreference.last
      expect(pref.saved_search).to eq(saved_search)
      expect(pref.user).to eq(user)
      expect(pref.hidden).to be true
    end

    it "shows a previously hidden search" do
      user = create(:user)
      saved_search = create(:saved_search)
      pref = create(:saved_search_preference, user: user, saved_search: saved_search, hidden: true)
      sign_in(user)

      post settings_saved_search_preferences_path, params: { saved_search_id: saved_search.id, hidden: false }

      expect(pref.reload.hidden).to be false
    end

    it "redirects guests to new_session_path" do
      saved_search = create(:saved_search)

      post settings_saved_search_preferences_path, params: { saved_search_id: saved_search.id, hidden: true }

      expect(response).to redirect_to(new_session_path)
    end
  end
end
