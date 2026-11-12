Rails.application.config.x.api_rate_limit.anonymous = Integer(ENV["API_RATE_LIMIT_ANONYMOUS"].presence || 60)
Rails.application.config.x.api_rate_limit.token = Integer(ENV["API_RATE_LIMIT_TOKEN"].presence || 600)

# per process: the effective limit scales with the number of web processes
Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new unless Rails.env.test?

class Rack::Attack
  PERIOD = 60

  def self.api_request?(req)
    ApiExceptionsApp::API_PATH.match?(req.path.b)
  end

  def self.api_token(req)
    Api::RequestToken.resolve(req.env).token if api_request?(req)
  end

  def self.ip_bucket(ip)
    addr = IPAddr.new(ip).native
    addr.ipv6? ? addr.mask(64).to_s : addr.to_s
  rescue ArgumentError
    ip
  end

  throttle(ApiRateLimitHeaders::TOKEN_THROTTLE, limit: ->(_req) { Rails.configuration.x.api_rate_limit.token }, period: PERIOD) do |req|
    api_token(req)&.id
  end

  throttle(ApiRateLimitHeaders::IP_THROTTLE, limit: ->(_req) { Rails.configuration.x.api_rate_limit.anonymous }, period: PERIOD) do |req|
    next unless api_request?(req)
    next if api_token(req)

    ip_bucket((req.env["action_dispatch.remote_ip"] || req.ip).to_s)
  end

  self.throttled_responder = lambda do |req|
    next Configuration::DEFAULT_THROTTLED_RESPONDER.call(req) unless api_request?(req)

    reset = ApiRateLimitHeaders.build(req.env["rack.attack.match_data"])["ratelimit-reset"]
    body = { error: { code: "rate_limited", message: "Rate limit exceeded, retry in #{reset}s" } }
    [ 429, { "content-type" => "application/json; charset=utf-8", "retry-after" => reset }, [ body.to_json ] ]
  end
end

ActiveSupport::Notifications.subscribe("throttle.rack_attack") do |_name, _start, _finish, _id, payload|
  req = payload[:request]
  Rails.logger.info(
    "rack_attack throttle=#{req.env['rack.attack.matched']} discriminator=#{req.env['rack.attack.match_discriminator']} path=#{req.path}"
  )
end
