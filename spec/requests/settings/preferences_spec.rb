# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Settings::Preferences", type: :request do
  let(:user) { create(:user) }

  before { sign_in_as(user) }

  describe "PATCH /settings/preferences" do
    it "defaults collapse_quotes to off for new users" do
      expect(user.collapse_quotes).to be(false)
    end

    it "enables collapse_quotes" do
      patch settings_preferences_path, params: { user: { collapse_quotes: "1" } }

      expect(response).to redirect_to(settings_profile_path)
      expect(user.reload.collapse_quotes).to be(true)
    end

    it "disables collapse_quotes" do
      user.update!(collapse_quotes: true)

      patch settings_preferences_path, params: { user: { collapse_quotes: "0" } }

      expect(response).to redirect_to(settings_profile_path)
      expect(user.reload.collapse_quotes).to be(false)
    end
  end

  describe "GET /settings/profile" do
    it "shows the collapse quotes preference unchecked by default" do
      get settings_profile_path

      expect(response.body).to include("Collapse quoted text")
      checkbox = response.body.scan(/<input[^>]+>/).find do |tag|
        tag.include?("user[collapse_quotes]") && tag.include?('type="checkbox"')
      end
      expect(checkbox).to be_present
      expect(checkbox).not_to include("checked")
    end
  end
end
