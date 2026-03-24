# frozen_string_literal: true

require 'rails_helper'

RSpec.describe "Admin::MailingLists", type: :request do
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
      get admin_mailing_lists_path
      expect(response).to redirect_to(root_path)
    end

    it "redirects non-admin users" do
      sign_in(email: "regular@example.com")
      get admin_mailing_lists_path
      expect(response).to redirect_to(root_path)
    end
  end

  describe "GET /admin/mailing_lists" do
    before { sign_in(email: "admin@example.com") }

    it "lists mailing lists" do
      create(:mailing_list, identifier: "pgsql-hackers", display_name: "pgsql-hackers")

      get admin_mailing_lists_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("pgsql-hackers")
    end
  end

  describe "GET /admin/mailing_lists/new" do
    before { sign_in(email: "admin@example.com") }

    it "renders the new form" do
      get new_admin_mailing_list_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("New Mailing List")
    end
  end

  describe "POST /admin/mailing_lists" do
    before { sign_in(email: "admin@example.com") }

    it "creates a mailing list" do
      expect {
        post admin_mailing_lists_path, params: { mailing_list: { identifier: "pgsql-bugs", display_name: "pgsql-bugs", email: "pgsql-bugs@lists.postgresql.org" } }
      }.to change { MailingList.count }.by(1)

      expect(response).to redirect_to(admin_mailing_lists_path)
    end

    it "re-renders form on validation error" do
      post admin_mailing_lists_path, params: { mailing_list: { identifier: "", display_name: "" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("New Mailing List")
    end
  end

  describe "GET /admin/mailing_lists/:id/edit" do
    before { sign_in(email: "admin@example.com") }

    it "renders the edit form" do
      ml = create(:mailing_list)
      get edit_admin_mailing_list_path(ml)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Edit Mailing List")
    end
  end

  describe "PATCH /admin/mailing_lists/:id" do
    before { sign_in(email: "admin@example.com") }

    it "updates a mailing list" do
      ml = create(:mailing_list, identifier: "old-list", display_name: "Old List")

      patch admin_mailing_list_path(ml), params: { mailing_list: { display_name: "New Name" } }
      expect(response).to redirect_to(admin_mailing_lists_path)

      ml.reload
      expect(ml.display_name).to eq("New Name")
    end

    it "re-renders form on validation error" do
      ml = create(:mailing_list)
      patch admin_mailing_list_path(ml), params: { mailing_list: { identifier: "" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Edit Mailing List")
    end
  end
end
