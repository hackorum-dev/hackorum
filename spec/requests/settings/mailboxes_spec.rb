# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Settings mailbox", type: :request do
  let(:user) { create(:user, username: "dutow") }

  before { sign_in_as(user) }

  it "redirects users without a mailbox and hides the nav link" do
    get settings_mailbox_path
    expect(response).to redirect_to(settings_root_path)
    patch settings_mailbox_path, params: { password: "a long mail password", password_confirmation: "a long mail password" }
    expect(response).to redirect_to(settings_root_path)
    get settings_account_path
    expect(response.body).not_to include(settings_mailbox_path)
  end

  context "with a mailbox" do
    let!(:mailbox) { Mailbox.grant!(user: user, login: "dutow").tap { |m| m.add_alias("zsolt.parragi") } }

    it "shows the nav link" do
      get settings_account_path
      expect(response.body).to include(settings_mailbox_path)
    end

    it "shows connection settings when mail is configured" do
      allow(MailConfig).to receive_messages(available?: true, domain: "hackorum.test", host: "mail.hackorum.test", webmail_host: "webmail.hackorum.test")
      get settings_mailbox_path
      expect(response.body).to include("dutow@hackorum.test", "zsolt.parragi@hackorum.test", "mail.hackorum.test", "993", "465", "587", "https://webmail.hackorum.test")
    end

    it "asks before generating a password" do
      get settings_mailbox_path
      expect(response.body).to include("Replace the current mail password? Mail clients using the old one stop working.")
    end

    it "treats a blank mail host as not available" do
      allow(MailConfig).to receive_messages(available?: true, domain: "hackorum.test", host: "", webmail_host: nil)
      get settings_mailbox_path
      expect(response.body).to include("Mail is not available on this server.")
      expect(response.body).not_to include("993")
    end

    it "says so when mail is not configured" do
      allow(MailConfig).to receive_messages(available?: false, domain: nil, host: nil, webmail_host: nil)
      get settings_mailbox_path
      expect(response.body).to include("Mail is not available on this server.", "dutow@", "new-password")
      expect(response.body).not_to include("993")
    end

    it "sets a password" do
      patch settings_mailbox_path, params: { password: "a long mail password", password_confirmation: "a long mail password" }
      expect(flash[:notice]).to eq("Mail password updated.")
      expect(MailPasswordHash.matches?(mailbox.reload.password_hash, "a long mail password")).to be(true)
    end

    it "rejects mismatch and short passwords" do
      before = mailbox.password_hash
      patch settings_mailbox_path, params: { password: "a long mail password", password_confirmation: "another long password" }
      expect(flash[:alert]).to eq("Passwords do not match")
      patch settings_mailbox_path, params: { password: "short", password_confirmation: "short" }
      expect(flash[:alert]).to include("too short")
      expect(mailbox.reload.password_hash).to eq(before)
    end

    it "generates a password and shows it once" do
      post generate_settings_mailbox_path
      expect(response).to have_http_status(:ok)
      expect(response.headers["Cache-Control"]).to include("no-store")
      shown = response.body[/value="([A-Za-z0-9]{24})"/, 1]
      expect(MailPasswordHash.matches?(mailbox.reload.password_hash, shown)).to be(true)
      get settings_mailbox_path
      expect(response.body).not_to include(shown)
    end

    it "blocks password changes on a disabled mailbox" do
      mailbox.disable!
      before = mailbox.password_hash
      post generate_settings_mailbox_path
      expect(flash[:alert]).to eq("This mailbox is disabled.")
      patch settings_mailbox_path, params: { password: "a long mail password", password_confirmation: "a long mail password" }
      expect(flash[:alert]).to eq("This mailbox is disabled.")
      expect(mailbox.reload.password_hash).to eq(before)
      get settings_mailbox_path
      expect(response.body).to include("This mailbox is disabled.")
    end

    it "does not touch another user's mailbox" do
      other = grant_mailbox(login: "eve")
      before = other.password_hash
      patch settings_mailbox_path, params: { password: "a long mail password", password_confirmation: "a long mail password" }
      expect(other.reload.password_hash).to eq(before)
    end
  end
end
