require "rails_helper"

RSpec.describe "API v1 rate limiting", type: :request do
  let(:limits) { Rails.configuration.x.api_rate_limit }

  around do |example|
    old_store = Rack::Attack.cache.store
    old_limits = @default_limits = [ limits.anonymous, limits.token ]
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    limits.anonymous = 2
    limits.token = 4
    freeze_time { example.run }
  ensure
    Rack::Attack.cache.store = old_store
    limits.anonymous, limits.token = old_limits
  end

  def bearer(user = create(:user))
    { "Authorization" => "Bearer #{ApiToken.issue!(user: user, name: 't').last}" }
  end

  def expect_budget(limit:, remaining:)
    expect(response.headers["RateLimit-Limit"]).to eq(limit.to_s)
    expect(response.headers["RateLimit-Remaining"]).to eq(remaining.to_s)
    expect(response.headers["RateLimit-Reset"].to_i).to be_between(1, 60)
  end

  it "throttles anonymous callers per IP" do
    2.times do
      get "/api/v1/me"
      expect(response).to have_http_status(:unauthorized)
    end

    get "/api/v1/me"

    expect(response).to have_http_status(:too_many_requests)
    expect(response.content_type).to eq("application/json; charset=utf-8")
    expect(JSON.parse(response.body).dig("error", "code")).to eq("rate_limited")
    expect(response.headers["Retry-After"].to_i).to be_between(1, 60)
    expect(response.headers["RateLimit-Remaining"]).to eq("0")
  end

  it "logs a throttled request without the token" do
    headers = bearer
    token = ApiToken.last
    lines = []
    allow(Rails.logger).to receive(:info).and_wrap_original do |original, *args, &block|
      lines << (args.first || block&.call).to_s
      original.call(*args, &block)
    end

    5.times { get "/api/v1/me?secret=1", headers: headers }

    expect(response).to have_http_status(:too_many_requests)
    throttled = lines.grep(/rack_attack/)
    expect(throttled.size).to eq(1)
    expect(throttled.first).to include(ApiRateLimitHeaders::TOKEN_THROTTLE, token.id.to_s, "/api/v1/me")
    expect(throttled.first).not_to include("hko_", "Bearer", "secret")
  end

  it "gives a token its own higher limit" do
    headers = bearer
    4.times do
      get "/api/v1/me", headers: headers
      expect(response).to have_http_status(:ok)
    end
    get "/api/v1/me", headers: headers
    expect(response).to have_http_status(:too_many_requests)

    get "/api/v1/me", headers: bearer
    expect(response).to have_http_status(:ok)
  end

  it "counts invalid tokens against the IP" do
    3.times { |i| get "/api/v1/me", headers: { "Authorization" => "Bearer hko_fake#{i}" } }
    expect(response).to have_http_status(:too_many_requests)
  end

  it "reports the budget on normal responses" do
    get "/api/v1/me", headers: bearer

    expect_budget(limit: 4, remaining: 3)
  end

  it "reports the budget on a 401" do
    get "/api/v1/me"

    expect(response).to have_http_status(:unauthorized)
    expect_budget(limit: 2, remaining: 1)
  end

  it "reports the budget on a 404" do
    get "/api/v1/no/such/thing"

    expect(response).to have_http_status(:not_found)
    expect_budget(limit: 2, remaining: 1)
  end

  it "reports the budget on errors answered outside the controller" do
    config = Rails.application.env_config
    saved = config.slice("action_dispatch.show_exceptions", "action_dispatch.show_detailed_exceptions")
    config["action_dispatch.show_exceptions"] = :all
    config["action_dispatch.show_detailed_exceptions"] = false

    get "/api/v1/me?x=%ff"

    expect(response).to have_http_status(:bad_request)
    expect(response.media_type).to eq("application/json")
    expect_budget(limit: 2, remaining: 1)
  ensure
    config.merge!(saved)
  end

  it "leaves the site and the lineage API alone" do
    5.times { get "/help" }
    expect(response).not_to have_http_status(:too_many_requests)
    expect(response.headers["RateLimit-Limit"]).to be_nil

    5.times { get "/api/lineage/queue" }
    expect(response).not_to have_http_status(:too_many_requests)
    expect(response.headers["RateLimit-Limit"]).to be_nil
  end

  it "covers the API root with a format suffix" do
    2.times do
      get "/api/v1.json"
      expect(response).to have_http_status(:not_found)
    end
    expect_budget(limit: 2, remaining: 0)

    get "/api/v1.xml"
    expect(response).to have_http_status(:too_many_requests)
  end

  it "buckets IPv6 callers per /64" do
    get "/api/v1/me", headers: { "REMOTE_ADDR" => "2001:db8:1:2::1" }
    expect_budget(limit: 2, remaining: 1)

    get "/api/v1/me", headers: { "REMOTE_ADDR" => "2001:db8:1:2:ffff::9" }
    expect_budget(limit: 2, remaining: 0)

    get "/api/v1/me", headers: { "REMOTE_ADDR" => "2001:db8:1:3::1" }
    expect_budget(limit: 2, remaining: 1)
  end

  it "keeps IPv4 callers apart" do
    get "/api/v1/me", headers: { "REMOTE_ADDR" => "203.0.113.5" }
    expect_budget(limit: 2, remaining: 1)

    get "/api/v1/me", headers: { "REMOTE_ADDR" => "203.0.113.6" }
    expect_budget(limit: 2, remaining: 1)
  end

  it "ignores throttle data of other throttles" do
    data = { limit: 9, count: 1, period: 60, epoch_time: Time.now.to_i }
    app = ->(env) { env["rack.attack.throttle_data"] = { "site/ip" => data }; [ 200, {}, [] ] }

    _status, headers, = ApiRateLimitHeaders.new(app).call({})

    expect(headers).to be_empty
  end

  it "answers throttled site requests like rack-attack does" do
    env = Rack::MockRequest.env_for("/topics")
    env["rack.attack.match_data"] = { limit: 1, count: 2, period: 60, epoch_time: Time.now.to_i }
    request = Rack::Attack::Request.new(env)

    expect(Rack::Attack.throttled_responder.call(request))
      .to eq(Rack::Attack::Configuration::DEFAULT_THROTTLED_RESPONDER.call(request))
  end

  it "defaults to 60 and 600 requests a minute" do
    expect(@default_limits).to eq([ 60, 600 ])
  end

  it "sits where it can see the client IP and decorate error responses" do
    order = Rails.application.middleware.map(&:name)

    expect(order.index("ActionDispatch::RemoteIp")).to be < order.index("Rack::Attack")
    expect(order.index("ApiRateLimitHeaders")).to be < order.index("ActionDispatch::ShowExceptions")
  end
end
