require "rails_helper"

RSpec.describe "Admin::Mailboxes", type: :request do
  let(:admin) { create(:user, admin: true, username: "boss") }
  let!(:user) { create(:user, username: "dutow") }

  before { sign_in_as(admin) }

  it "rejects non-admins" do
    sign_in_as(create(:user))
    get admin_mailboxes_path
    expect(response).to redirect_to(root_path)
  end

  it "lists mailboxes" do
    Mailbox.grant!(user: user, login: "dutow").add_alias("zsolt.parragi")
    get admin_mailboxes_path
    expect(response.body).to include("dutow", "zsolt.parragi", "5 GB", "active")
  end

  it "grants with defaults" do
    post admin_mailboxes_path, params: { mailbox: { username: "Dutow", login: "", quota_mb: "" } }
    expect(response).to redirect_to(edit_admin_mailbox_path(user.reload.mailbox))
    expect(user.mailbox.login_local_part).to eq("dutow")
    expect(user.mailbox.quota_mb).to eq(5120)
  end

  it "grants with a different login and quota" do
    post admin_mailboxes_path, params: { mailbox: { username: "dutow", login: "zsolt", quota_mb: "1024" } }
    expect(user.reload.mailbox.login_local_part).to eq("zsolt")
    expect(user.mailbox.quota_mb).to eq(1024)
  end

  it "re-renders on unknown user, taken login and bad default login" do
    create(:user, username: "_odd")
    create(:user, username: "alice")
    create(:team, name: "core")
    [ { username: "nobody" }, { username: "dutow", login: "alice" }, { username: "dutow", login: "core" }, { username: "_odd" } ].each do |attrs|
      post admin_mailboxes_path, params: { mailbox: attrs }
      expect(response).to have_http_status(:unprocessable_content)
    end
    expect(Mailbox.count).to eq(0)
  end

  it "rejects non-admins on mutating actions" do
    sign_in_as(create(:user))
    post admin_mailboxes_path, params: { mailbox: { username: "dutow" } }
    expect(response).to redirect_to(root_path)
    expect(Mailbox.count).to eq(0)
  end

  it "updates the quota only" do
    mailbox = Mailbox.grant!(user: user, login: "dutow")
    patch admin_mailbox_path(mailbox), params: { mailbox: { quota_mb: "2048", login: "x" } }
    expect(mailbox.reload.quota_mb).to eq(2048)
    expect(mailbox.login_local_part).to eq("dutow")
  end

  it "adds and removes aliases" do
    mailbox = Mailbox.grant!(user: user, login: "dutow")
    post admin_mailbox_addresses_path(mailbox), params: { local_part: "Zsolt.Parragi" }
    addr = mailbox.alias_addresses.find_by!(local_part: "zsolt.parragi")
    post admin_mailbox_addresses_path(mailbox), params: { local_part: "postmaster" }
    expect(flash[:alert]).to include("is reserved")
    delete admin_mailbox_address_path(mailbox, addr)
    expect(mailbox.alias_addresses).to be_empty
    delete admin_mailbox_address_path(mailbox, mailbox.login_address)
    expect(mailbox.reload.login_address).to be_present
  end

  it "does not remove an address through another mailbox" do
    mailbox = Mailbox.grant!(user: user, login: "dutow")
    address = mailbox.add_alias("zsolt.parragi")
    other = Mailbox.grant!(user: create(:user, username: "alice"), login: "alice")
    delete admin_mailbox_address_path(other, address)
    expect(response).to have_http_status(:not_found)
    expect(MailboxAddress.exists?(address.id)).to be(true)
  end

  it "refuses to enable the mailbox of a deleted user" do
    mailbox = Mailbox.grant!(user: user, login: "dutow")
    mailbox.disable!
    user.update_columns(deleted_at: Time.current)
    get admin_mailboxes_path
    expect(response.body).to include("Deleted user", "disabled")
    post enable_admin_mailbox_path(mailbox)
    expect(response).to redirect_to(admin_mailboxes_path)
    expect(flash[:alert]).to eq("User is deleted")
    expect(mailbox.reload).to be_disabled
  end

  it "disables, enables and deletes only when disabled" do
    mailbox = Mailbox.grant!(user: user, login: "dutow")
    mailbox.add_alias("zsolt.parragi")
    delete admin_mailbox_path(mailbox)
    expect(flash[:alert]).to eq("Disable the mailbox first")
    get confirm_destroy_admin_mailbox_path(mailbox)
    expect(response).to redirect_to(admin_mailboxes_path)
    expect(flash[:alert]).to eq("Disable the mailbox first")
    expect(Mailbox.exists?(mailbox.id)).to be(true)
    get admin_mailboxes_path
    expect(response.body).not_to include(confirm_destroy_admin_mailbox_path(mailbox))
    post disable_admin_mailbox_path(mailbox)
    expect(mailbox.reload).to be_disabled
    post enable_admin_mailbox_path(mailbox)
    expect(mailbox.reload).not_to be_disabled
    post disable_admin_mailbox_path(mailbox)
    get admin_mailboxes_path
    expect(response.body).to include(confirm_destroy_admin_mailbox_path(mailbox))
    get confirm_destroy_admin_mailbox_path(mailbox)
    expect(response.body).to include("Remove its maildir on the mail server first")
    expect(response.body).to include("dutow", "zsolt.parragi", "Delete mailbox dutow@")
    expect(response.body).not_to include("/var/mail/")
    allow(MailConfig).to receive(:domain).and_return("hackorum.test")
    get confirm_destroy_admin_mailbox_path(mailbox)
    expect(response.body).to include("/var/mail/hackorum.test/dutow/")
    delete admin_mailbox_path(mailbox)
    expect(Mailbox.exists?(mailbox.id)).to be(false)
  end
end
