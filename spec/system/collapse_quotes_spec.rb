# frozen_string_literal: true

require "rails_helper"

# End-to-end browser flow for the collapse-quotes preference. The feature is
# fully server-rendered (native <details> elements), so the rack_test driver
# exercises the complete login -> settings -> thread flow without JS.
RSpec.describe "Collapse quotes setting", type: :system do
  before { driven_by(:rack_test) }

  let(:email) { "tester@example.com" }
  let(:password) { "secret-password" }

  let!(:user) do
    user = create(:user, username: "tester", password: password)
    al = create(:alias, user: user, email: email, verified_at: Time.current)
    user.person.update!(default_alias_id: al.id)
    user
  end

  let(:message_body) do
    <<~BODY
      On Mon, Jun 1, 2026 Alice wrote:
      > inline quoted point

      Reply to the inline quote.
    BODY
  end

  let!(:topic) { create(:topic) }
  let!(:message) { create(:message, topic: topic, body: message_body) }

  def sign_in
    visit new_session_path
    fill_in "Email", with: email
    fill_in "Password", with: password
    click_button "Log In"
    expect(page).to have_content("Signed in successfully")
  end

  it "is off by default and collapses quotes once enabled from settings" do
    sign_in

    # Default: setting is off, quotes render uncollapsed
    visit settings_profile_path
    expect(page).to have_unchecked_field("user[collapse_quotes]")

    visit topic_path(topic)
    expect(page).to have_no_css("details.quoted-block")
    expect(page).to have_css("blockquote", text: "inline quoted point")

    # Enable the setting through the real form
    visit settings_profile_path
    check "user[collapse_quotes]"
    click_button "Save", exact: true
    expect(page).to have_content("Preferences updated")
    expect(page).to have_checked_field("user[collapse_quotes]")

    # Quotes are now collapsed behind a "Show quoted text" toggle
    visit topic_path(topic)
    expect(page).to have_css("details.quoted-block summary", text: "Show quoted text")
    expect(page).to have_content("Reply to the inline quote.")

    # Turn it back off and confirm old behavior returns
    visit settings_profile_path
    uncheck "user[collapse_quotes]"
    click_button "Save", exact: true

    visit topic_path(topic)
    expect(page).to have_no_css("details.quoted-block")
  end
end
