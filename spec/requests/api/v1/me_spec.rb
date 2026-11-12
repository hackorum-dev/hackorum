require "rails_helper"

RSpec.describe "API v1 /me", type: :request do
  let(:user) { create(:user, username: "alice") }
  let(:issued) { ApiToken.issue!(user: user, name: "laptop") }
  let(:token) { issued.first }
  let(:headers) { { "Authorization" => "Bearer #{issued.last}" } }

  def error_code
    JSON.parse(response.body).dig("error", "code")
  end

  it "needs a token" do
    get "/api/v1/me"

    expect(response).to have_http_status(:unauthorized)
    expect(error_code).to eq("token_required")
    expect(response.media_type).to eq("application/json")
    expect(response.headers["WWW-Authenticate"]).to eq("Bearer")
  end

  it "rejects an unknown token instead of going anonymous" do
    get "/api/v1/me", headers: { "Authorization" => "Bearer hko_nope" }

    expect(response).to have_http_status(:unauthorized)
    expect(error_code).to eq("invalid_token")
    expect(response.headers["WWW-Authenticate"]).to eq("Bearer")
  end

  it "rejects a revoked token" do
    token.revoke!
    get "/api/v1/me", headers: headers

    expect(response).to have_http_status(:unauthorized)
    expect(error_code).to eq("invalid_token")
  end

  it "rejects an expired token" do
    token.update!(expires_at: 1.minute.ago)
    get "/api/v1/me", headers: headers

    expect(response).to have_http_status(:unauthorized)
    expect(error_code).to eq("invalid_token")
  end

  it "rejects other authorization schemes" do
    get "/api/v1/me", headers: { "Authorization" => "Basic #{Base64.strict_encode64('a:b')}" }

    expect(response).to have_http_status(:unauthorized)
    expect(error_code).to eq("invalid_token")
  end

  it "returns the token's user" do
    al = create(:alias, user: user, person: user.person, name: "Alice A", email: "alice@example.com", verified_at: Time.current)
    user.person.update!(default_alias_id: al.id)
    create(:user_feature, user: user, feature: "patchset_lineage")

    get "/api/v1/me", headers: headers

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body["username"]).to eq("alice")
    expect(body["person"]).to include("id" => user.person_id, "name" => "Alice A", "email" => "alice@example.com")
    expect(body["person"]["html_url"]).to end_with("/person/alice@example.com")
    expect(body["person"]["url"]).to end_with("/api/v1/people/alice%40example.com")
    expect(body["emails"]).to eq([ "alice@example.com" ])
    expect(body["features"]).to eq([ "patchset_lineage" ])
    expect(body["send_authorized"]).to be(false)
    expect(body["token"]).to include("name" => "laptop", "expires_at" => nil)
  end

  it "accepts a lowercase scheme" do
    get "/api/v1/me", headers: { "Authorization" => "bearer #{issued.last}" }

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["username"]).to eq("alice")
  end

  it "leaves unverified addresses out of emails" do
    create(:alias, user: user, person: user.person, email: "verified@example.com", verified_at: Time.current)
    create(:alias, user: user, person: user.person, email: "pending@example.com", verified_at: nil)

    get "/api/v1/me", headers: headers

    expect(JSON.parse(response.body)["emails"]).to eq([ "verified@example.com" ])
  end

  it "builds links from the configured host, not the Host header" do
    al = create(:alias, user: user, person: user.person, email: "alice@example.com", verified_at: Time.current)
    user.person.update!(default_alias_id: al.id)

    with_env("APP_HOST" => "hackorum.example") do
      get "/api/v1/me", headers: headers.merge("Host" => "evil.example")
    end

    expect(response).to have_http_status(:ok)
    html_url = JSON.parse(response.body).dig("person", "html_url")
    expect(html_url).to eq("https://hackorum.example/person/alice@example.com")
    expect(html_url).not_to include("evil.example")
  end

  it "records token use" do
    freeze_time do
      get "/api/v1/me", headers: headers
      expect(token.reload.last_used_at).to eq(Time.current)
    end
  end

  it "ignores browser sessions" do
    al = create(:alias, user: user, person: user.person, email: "login@example.com", verified_at: Time.current)
    user.person.update!(default_alias_id: al.id)
    user.update!(password: "secret-secret", password_confirmation: "secret-secret")
    post session_path, params: { email: al.email, password: "secret-secret" }
    expect(response).to redirect_to(root_path)

    get "/api/v1/me"

    expect(response).to have_http_status(:unauthorized)
    expect(error_code).to eq("token_required")
  end

  it "answers unknown paths with a JSON 404" do
    get "/api/v1/no/such/thing"

    expect(response).to have_http_status(:not_found)
    expect(error_code).to eq("not_found")
  end

  it "takes no query parameters" do
    get "/api/v1/me?x=1", headers: headers
    expect(response).to have_http_status(:bad_request)
    expect(error_code).to eq("invalid_parameter")

    get "/api/v1/me?x=1", headers: { "Authorization" => "Bearer hko_nope" }
    expect(response).to have_http_status(:unauthorized)

    get "/api/v1/no/such/thing?x=1&y="
    expect(response).to have_http_status(:not_found)
  end
end
