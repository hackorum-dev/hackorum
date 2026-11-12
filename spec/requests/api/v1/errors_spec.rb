require "rails_helper"

RSpec.describe "API v1 errors", type: :request do
  let(:user) { create(:user) }
  let(:issued) { ApiToken.issue!(user: user, name: "laptop") }
  let(:headers) { { "Authorization" => "Bearer #{issued.last}" } }

  around do |example|
    config = Rails.application.env_config
    keys = %w[action_dispatch.show_exceptions action_dispatch.show_detailed_exceptions]
    saved = config.slice(*keys)
    config["action_dispatch.show_exceptions"] = :all
    config["action_dispatch.show_detailed_exceptions"] = false
    example.run
  ensure
    config.merge!(saved)
  end

  def error
    JSON.parse(response.body).fetch("error")
  end

  def expect_json_error(status, code)
    expect(response).to have_http_status(status)
    expect(response.media_type).to eq("application/json")
    expect(error["code"]).to eq(code)
    expect(error["message"]).to be_present
  end

  describe "outside the controller" do
    it "answers a badly encoded query string" do
      get "/api/v1/me?x=%ff"
      expect_json_error(400, "bad_request")
    end

    it "answers a badly encoded path" do
      get "/api/v1/a%ffb"
      expect_json_error(400, "bad_request")
    end

    it "answers a badly encoded email" do
      get "/api/v1/people/a%ffb"
      expect_json_error(400, "bad_request")

      get "/api/v1/people/%ff%ff"
      expect_json_error(400, "bad_request")
    end

    it "answers a badly encoded topic id or search" do
      get "/api/v1/topics/%ff"
      expect_json_error(400, "bad_request")

      get "/api/v1/topics?q=%ff"
      expect_json_error(400, "bad_request")
    end

    it "keeps its answers out of caches" do
      [ {}, headers ].each do |sent|
        get "/api/v1/topics?q=%ff", headers: sent

        expect_json_error(400, "bad_request")
        expect(response.headers["Cache-Control"]).to eq("no-store")
        expect(response.headers["Vary"].to_s).to include("Authorization")
      end
    end

    it "answers a failure on the API root with a format suffix" do
      get "/api/v1.json?x=%ff"
      expect_json_error(400, "bad_request")
    end

    it "answers conflicting parameter types" do
      get "/api/v1/me?a=1&a[b]=2"
      expect_json_error(400, "bad_request")
    end

    it "answers a malformed JSON body" do
      allow_any_instance_of(Api::V1::ErrorsController).to receive(:not_found) { |controller| controller.params.to_unsafe_h }

      post "/api/v1/whatever", params: "{", headers: { "Content-Type" => "application/json" }
      expect_json_error(400, "bad_request")
    end

    it "hides unhandled exceptions" do
      allow_any_instance_of(Api::V1::MeSerializer).to receive(:full).and_raise("boom")

      get "/api/v1/me", headers: headers

      expect_json_error(500, "internal_error")
      expect(response.body).not_to include("boom")
    end

    it "leaves the rest of the site on HTML error pages" do
      get "/topics?x=%ff"

      expect(response).to have_http_status(:bad_request)
      expect(response.media_type).to eq("text/html")
    end
  end

  describe "unknown endpoints" do
    it "answers GET on the API root" do
      get "/api/v1"
      expect_json_error(404, "not_found")
    end

    it "answers GET on the API root with a trailing slash" do
      get "/api/v1/"
      expect_json_error(404, "not_found")
    end

    it "answers POST on the API root" do
      post "/api/v1"
      expect_json_error(404, "not_found")
    end

    it "answers POST on a deeper path" do
      post "/api/v1/no/such/thing"
      expect_json_error(404, "not_found")
    end

    it "answers a known path with a format suffix" do
      get "/api/v1/me.json", headers: headers
      expect_json_error(404, "not_found")

      get "/api/v1/me.xml", headers: headers
      expect_json_error(404, "not_found")
    end

    it "records token use" do
      freeze_time do
        get "/api/v1/no/such/thing", headers: headers
        expect(issued.first.reload.last_used_at).to eq(Time.current)
      end
    end
  end
end
