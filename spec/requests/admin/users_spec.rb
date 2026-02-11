# frozen_string_literal: true

require 'rails_helper'

RSpec.describe "Admin::Users", type: :request do
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
      get admin_users_path
      expect(response).to redirect_to(root_path)
    end

    it "redirects non-admin users" do
      sign_in(email: "regular@example.com")
      get admin_users_path
      expect(response).to redirect_to(root_path)
    end
  end

  describe "GET /admin/users" do
    before { sign_in(email: "admin@example.com") }

    it "renders the user list" do
      get admin_users_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("admin_user")
      expect(response.body).to include("regular_user")
    end

    it "shows all email addresses for a user" do
      create(:alias, user: regular_user, person: regular_user.person, email: "second@example.com", name: "Second")

      get admin_users_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("regular@example.com")
      expect(response.body).to include("second@example.com")
    end

    it "marks the current user with (you)" do
      get admin_users_path
      expect(response.body).to include("(you)")
    end
  end

  describe "POST /admin/users/:id/toggle_admin" do
    before { sign_in(email: "admin@example.com") }

    it "grants admin to a regular user" do
      expect { post toggle_admin_admin_user_path(regular_user) }
        .to change { regular_user.reload.admin? }.from(false).to(true)

      expect(response).to redirect_to(admin_users_path)
      follow_redirect!
      expect(response.body).to include("now")
    end

    it "revokes admin from an admin user" do
      other_admin = create(:user, password: "secret", password_confirmation: "secret", admin: true, username: "other_admin")
      attach_verified_alias(other_admin, email: "other_admin@example.com")

      expect { post toggle_admin_admin_user_path(other_admin) }
        .to change { other_admin.reload.admin? }.from(true).to(false)

      expect(response).to redirect_to(admin_users_path)
      follow_redirect!
      expect(response.body).to include("no longer")
    end

    it "refuses to toggle own admin status" do
      expect { post toggle_admin_admin_user_path(admin) }
        .not_to change { admin.reload.admin? }

      expect(response).to redirect_to(admin_users_path)
      follow_redirect!
      expect(response.body).to include("cannot change your own")
    end

    it "blocks non-admin users" do
      sign_in(email: "regular@example.com")
      post toggle_admin_admin_user_path(admin)
      expect(response).to redirect_to(root_path)
    end
  end

  describe "GET /admin/users/:id/new_email" do
    before { sign_in(email: "admin@example.com") }

    it "renders the add email form" do
      get new_email_admin_user_path(regular_user)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("regular_user")
      expect(response.body).to include("Look up email")
    end
  end

  describe "POST /admin/users/:id/confirm_email" do
    before { sign_in(email: "admin@example.com") }

    it "shows confirmation page for a new email" do
      post confirm_email_admin_user_path(regular_user), params: { email: "new@example.com" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("new@example.com")
      expect(response.body).to include("Confirm association")
    end

    it "shows existing aliases when the email already has aliases" do
      create(:alias, email: "existing@example.com", name: "Legacy Name")

      post confirm_email_admin_user_path(regular_user), params: { email: "existing@example.com" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Legacy Name")
      expect(response.body).to include("existing@example.com")
    end

    it "warns when the email belongs to another user" do
      other = create(:user, username: "other_person")
      attach_verified_alias(other, email: "taken@example.com")

      post confirm_email_admin_user_path(regular_user), params: { email: "taken@example.com" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("already linked to another user")
      expect(response.body).not_to include("Confirm association")
    end

    it "redirects when email is blank" do
      post confirm_email_admin_user_path(regular_user), params: { email: "" }
      expect(response).to redirect_to(new_email_admin_user_path(regular_user))
    end
  end

  describe "POST /admin/users/:id/add_email" do
    before { sign_in(email: "admin@example.com") }

    it "creates a new alias for the user when email has no existing aliases" do
      expect {
        post add_email_admin_user_path(regular_user), params: { email: "brand-new@example.com" }
      }.to change { Alias.by_email("brand-new@example.com").count }.by(1)

      expect(response).to redirect_to(admin_users_path)

      al = Alias.by_email("brand-new@example.com").first
      expect(al.user_id).to eq(regular_user.id)
      expect(al.person_id).to eq(regular_user.person_id)
      expect(al.verified_at).to be_present
    end

    it "creates an AdminEmailChange record for a new alias" do
      expect {
        post add_email_admin_user_path(regular_user), params: { email: "brand-new@example.com" }
      }.to change { AdminEmailChange.count }.by(1)

      record = AdminEmailChange.last
      expect(record.performed_by).to eq(admin)
      expect(record.target_user).to eq(regular_user)
      expect(record.email).to eq("brand-new@example.com")
      expect(record.created_new_alias).to be true
      expect(record.aliases_attached).to eq(0)
    end

    it "attaches existing unowned aliases to the user" do
      orphan = create(:alias, email: "orphan@example.com", name: "Orphan Alias")

      expect {
        post add_email_admin_user_path(regular_user), params: { email: "orphan@example.com" }
      }.not_to change { Alias.count }

      expect(response).to redirect_to(admin_users_path)

      orphan.reload
      expect(orphan.user_id).to eq(regular_user.id)
      expect(orphan.person_id).to eq(regular_user.person_id)
      expect(orphan.verified_at).to be_present
    end

    it "creates an AdminEmailChange record when attaching existing aliases" do
      create(:alias, email: "orphan@example.com", name: "Orphan Alias")

      expect {
        post add_email_admin_user_path(regular_user), params: { email: "orphan@example.com" }
      }.to change { AdminEmailChange.count }.by(1)

      record = AdminEmailChange.last
      expect(record.performed_by).to eq(admin)
      expect(record.target_user).to eq(regular_user)
      expect(record.email).to eq("orphan@example.com")
      expect(record.created_new_alias).to be false
      expect(record.aliases_attached).to eq(1)
    end

    it "attaches multiple existing unowned aliases for the same email" do
      create(:alias, email: "multi@example.com", name: "Name A")
      create(:alias, email: "multi@example.com", name: "Name B")

      post add_email_admin_user_path(regular_user), params: { email: "multi@example.com" }
      expect(response).to redirect_to(admin_users_path)

      aliases = Alias.by_email("multi@example.com")
      expect(aliases.count).to eq(2)
      expect(aliases.pluck(:user_id).uniq).to eq([ regular_user.id ])
      expect(aliases.where(verified_at: nil)).to be_empty
    end

    it "refuses when email belongs to another user" do
      other = create(:user)
      attach_verified_alias(other, email: "owned@example.com")

      expect {
        post add_email_admin_user_path(regular_user), params: { email: "owned@example.com" }
      }.not_to change { AdminEmailChange.count }

      expect(response).to redirect_to(admin_users_path)
      follow_redirect!
      expect(response.body).to include("linked to another account")

      expect(Alias.by_email("owned@example.com").first.user_id).to eq(other.id)
    end

    it "does not create an audit record when email is blank" do
      expect {
        post add_email_admin_user_path(regular_user), params: { email: "" }
      }.not_to change { AdminEmailChange.count }

      expect(response).to redirect_to(admin_users_path)
    end

    it "blocks non-admin users" do
      sign_in(email: "regular@example.com")
      post add_email_admin_user_path(admin), params: { email: "hack@example.com" }
      expect(response).to redirect_to(root_path)
      expect(Alias.by_email("hack@example.com")).not_to exist
    end
  end
end
