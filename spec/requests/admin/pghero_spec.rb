# frozen_string_literal: true

require 'rails_helper'

RSpec.describe "PgHero mount", type: :request do
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

  it "is not routable for guests" do
    get "/admin/pghero"
    expect(response).to have_http_status(:not_found)
  end

  it "is not routable for non-admins" do
    sign_in(email: "regular@example.com")
    get "/admin/pghero"
    expect(response).to have_http_status(:not_found)
  end

  it "is routable for admins" do
    # CI postgres lacks pg_stat_statements preload; probe error aborts the test txn
    allow_any_instance_of(PgHero::Database).to receive(:query_stats_readable?).and_return(false)
    sign_in(email: "admin@example.com")
    get "/admin/pghero"
    expect(response).not_to have_http_status(:not_found)
  end
end
