# frozen_string_literal: true

require 'rails_helper'

RSpec.describe "Admin::People", type: :request do
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

  before { attach_verified_alias(admin, email: "admin@example.com") }

  describe "access control" do
    it "redirects unauthenticated users" do
      get admin_people_path
      expect(response).to redirect_to(root_path)
    end

    it "redirects non-admin users" do
      regular = create(:user, password: "secret", password_confirmation: "secret", username: "regular_user")
      attach_verified_alias(regular, email: "regular@example.com")

      sign_in(email: "regular@example.com")
      get admin_people_path
      expect(response).to redirect_to(root_path)
    end
  end

  describe "GET /admin/people" do
    before { sign_in(email: "admin@example.com") }

    it "lists people with their emails" do
      person = create(:person)
      create(:alias, person: person, name: "Zoltan Tester", email: "zoltan@example.com", sender_count: 4)

      get admin_people_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Zoltan Tester")
      expect(response.body).to include("zoltan@example.com")
    end

    it "includes people that have no default alias" do
      orphan = create(:person)

      get admin_people_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(new_admin_person_merge_path(orphan))
    end

    it "orders by default alias name" do
      first = create(:person)
      create(:alias, person: first, name: "Aaron First", email: "aaron@example.com")
      last = create(:person)
      create(:alias, person: last, name: "Zed Last", email: "zed@example.com")

      get admin_people_path

      expect(response.body.index("Aaron First")).to be < response.body.index("Zed Last")
    end

    it "matches search against a non-default alias" do
      person = create(:person)
      create(:alias, person: person, name: "Primary Name", email: "primary@example.com")
      create(:alias, person: person, name: "Hidden Handle", email: "hidden@elsewhere.test")
      other = create(:person)
      create(:alias, person: other, name: "Unrelated Person", email: "unrelated@example.com")

      get admin_people_path(q: "elsewhere.test")

      expect(response.body).to include("Primary Name")
      expect(response.body).not_to include("Unrelated Person")
    end

    it "treats LIKE wildcards literally" do
      person = create(:person)
      create(:alias, person: person, name: "Wildcard Victim", email: "victim@example.com")

      get admin_people_path(q: "%")

      expect(response.body).not_to include("Wildcard Victim")
    end

    it "filters to registered people" do
      registered = create(:user, username: "registered_person")
      attach_verified_alias(registered, email: "registered@example.com")
      anonymous = create(:person)
      create(:alias, person: anonymous, name: "Anonymous Poster", email: "anon@example.com")

      get admin_people_path(registered: "registered")

      expect(response.body).to include("registered@example.com")
      expect(response.body).not_to include("Anonymous Poster")
    end

    it "filters to unregistered people" do
      registered = create(:user, username: "registered_person")
      attach_verified_alias(registered, email: "registered@example.com")
      anonymous = create(:person)
      create(:alias, person: anonymous, name: "Anonymous Poster", email: "anon@example.com")

      get admin_people_path(registered: "unregistered")

      expect(response.body).to include("Anonymous Poster")
      expect(response.body).not_to include("registered@example.com")
    end

    it "hides mention-only people when senders is set" do
      sender = create(:person)
      create(:alias, person: sender, name: "Actual Sender", email: "sender@example.com", sender_count: 9)
      lurker = create(:person)
      create(:alias, person: lurker, name: "Mentioned Only", email: "lurker@example.com", sender_count: 0)

      get admin_people_path(senders: "1")

      expect(response.body).to include("Actual Sender")
      expect(response.body).not_to include("Mentioned Only")
    end

    it "combines search with the sender filter" do
      match = create(:person)
      create(:alias, person: match, name: "Searchable Sender", email: "match@example.com", sender_count: 2)
      quiet = create(:person)
      create(:alias, person: quiet, name: "Searchable Lurker", email: "quiet@example.com", sender_count: 0)

      get admin_people_path(q: "Searchable", senders: "1")

      expect(response.body).to include("Searchable Sender")
      expect(response.body).not_to include("Searchable Lurker")
    end

    it "paginates" do
      stub_const("Admin::PeopleController::PER_PAGE", 1)
      first = create(:person)
      create(:alias, person: first, name: "Aaron Paged", email: "aaron@example.com")
      second = create(:person)
      create(:alias, person: second, name: "Zed Paged", email: "zed@example.com")

      get admin_people_path(q: "Paged")

      expect(response.body).to include("Aaron Paged")
      expect(response.body).not_to include("Zed Paged")

      get admin_people_path(q: "Paged", page: 2)

      expect(response.body).to include("Zed Paged")
      expect(response.body).not_to include("Aaron Paged")
    end
  end
end
