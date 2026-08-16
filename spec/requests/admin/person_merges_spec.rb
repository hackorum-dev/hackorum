# frozen_string_literal: true

require 'rails_helper'

RSpec.describe "Admin::PersonMerges", type: :request do
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
  let(:source) { create(:person) }
  let(:target) { create(:person) }

  before do
    attach_verified_alias(admin, email: "admin@example.com")
    create(:alias, person: source, name: "Source Person", email: "source@example.com", sender_count: 3)
    create(:alias, person: target, name: "Target Person", email: "target@example.com", sender_count: 5)
  end

  describe "access control" do
    it "redirects non-admin users from new" do
      regular = create(:user, password: "secret", password_confirmation: "secret", username: "regular_user")
      attach_verified_alias(regular, email: "regular@example.com")

      sign_in(email: "regular@example.com")
      get new_admin_person_merge_path(source)
      expect(response).to redirect_to(root_path)
    end

    it "redirects unauthenticated users from the audit log" do
      get admin_person_merges_path
      expect(response).to redirect_to(root_path)
    end

    it "refuses a non-admin posting straight to preview and create" do
      regular = create(:user, password: "secret", password_confirmation: "secret", username: "regular_user")
      attach_verified_alias(regular, email: "regular@example.com")
      sign_in(email: "regular@example.com")

      post preview_admin_person_merge_path(source), params: { target_person_id: target.id }
      expect(response).to redirect_to(root_path)

      post admin_person_merge_path(source), params: { target_person_id: target.id }
      expect(response).to redirect_to(root_path)
      expect(Person.find_by(id: source.id)).to be_present
      expect(PersonMerge.count).to eq(0)
    end
  end

  describe "GET new" do
    before { sign_in(email: "admin@example.com") }

    it "shows the source person" do
      get new_admin_person_merge_path(source)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Source Person")
      expect(response.body).to include("source@example.com")
    end

    it "lists candidate targets matching the search" do
      get new_admin_person_merge_path(source, target_q: "Target")

      expect(response.body).to include("Target Person")
    end

    it "excludes the source from its own candidates" do
      get new_admin_person_merge_path(source, target_q: "Person")

      expect(response.body).to include("Target Person")
      expect(response.body.scan("source@example.com").size).to eq(1)
    end
  end

  describe "POST preview" do
    before { sign_in(email: "admin@example.com") }

    it "shows what would move" do
      post preview_admin_person_merge_path(source), params: { target_person_id: target.id }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Source Person")
      expect(response.body).to include("Target Person")
      expect(response.body).to include("Confirm Merge")
    end

    it "requires a target" do
      post preview_admin_person_merge_path(source), params: { target_person_id: "" }

      expect(response).to redirect_to(new_admin_person_merge_path(source))
      expect(flash[:alert]).to match(/Target person is required/)
    end

    it "refuses a source that has a user account" do
      registered = create(:user, username: "registered_person")
      attach_verified_alias(registered, email: "registered@example.com")

      post preview_admin_person_merge_path(registered.person), params: { target_person_id: target.id }

      expect(response).to redirect_to(new_admin_person_merge_path(registered.person))
      expect(flash[:alert]).to match(/user account/)
    end
  end

  describe "POST create" do
    before { sign_in(email: "admin@example.com") }

    it "merges and records the audit row" do
      post admin_person_merge_path(source), params: { target_person_id: target.id }

      expect(response).to redirect_to(admin_people_path)
      expect(flash[:notice]).to match(/Source Person/)
      expect(Person.find_by(id: source.id)).to be_nil
      expect(Alias.by_email("source@example.com").first.person_id).to eq(target.id)

      audit = PersonMerge.last
      expect(audit.source_name).to eq("Source Person")
      expect(audit.target_person_id).to eq(target.id)
      expect(audit.performed_by).to eq(admin)
    end

    it "revalidates when preview is skipped entirely" do
      registered = create(:user, username: "registered_person")
      attach_verified_alias(registered, email: "registered@example.com")

      post admin_person_merge_path(registered.person), params: { target_person_id: target.id }

      expect(response).to redirect_to(new_admin_person_merge_path(registered.person))
      expect(flash[:alert]).to match(/user account/)
      expect(Person.find_by(id: registered.person_id)).to be_present
      expect(PersonMerge.count).to eq(0)
    end

    it "reports a rejected merge and changes nothing" do
      post admin_person_merge_path(source), params: { target_person_id: source.id }

      expect(response).to redirect_to(new_admin_person_merge_path(source))
      expect(flash[:alert]).to match(/into itself/)
      expect(Person.find_by(id: source.id)).to be_present
      expect(PersonMerge.count).to eq(0)
    end
  end

  describe "GET index" do
    before { sign_in(email: "admin@example.com") }

    it "lists past merges" do
      post admin_person_merge_path(source), params: { target_person_id: target.id }

      get admin_person_merges_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Source Person")
      expect(response.body).to include("source@example.com")
      expect(response.body).to include("admin_user")
    end

    it "still renders when the target has since been deleted" do
      create(:person_merge, performed_by: admin, target_person_id: 999_999_999,
                            source_name: "Ghost Source", target_name: "Ghost Target")

      get admin_person_merges_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Ghost Target")
    end

    it "shows an empty state when nothing has been merged" do
      get admin_person_merges_path

      expect(response.body).to include("No people have been merged yet.")
    end
  end
end
