# frozen_string_literal: true

class ApiRateLimitHeaders
  TOKEN_THROTTLE = "api/token"
  IP_THROTTLE = "api/ip"
  VARY = "Authorization"

  def self.build(data)
    {
      "ratelimit-limit" => data[:limit].to_s,
      "ratelimit-remaining" => [ data[:limit] - data[:count], 0 ].max.to_s,
      "ratelimit-reset" => (data[:period] - (data[:epoch_time] % data[:period])).to_s
    }
  end

  # the headers with Authorization in Vary
  def self.vary(headers)
    current, kept = headers.partition { |name, _| name.to_s.casecmp?("vary") }
    names = current.flat_map { |_, value| Array(value) }.join(",").split(",").map(&:strip).reject(&:empty?)
    kept.to_h.merge("vary" => (names.reject { |name| name.casecmp?(VARY) } + [ VARY ]).join(", "))
  end

  def initialize(app)
    @app = app
  end

  def call(env)
    # the exceptions app rewrites the path
    api = ApiExceptionsApp::API_PATH.match?(env["PATH_INFO"].to_s.b)
    status, headers, body = @app.call(env)
    data = env["rack.attack.throttle_data"]&.values_at(TOKEN_THROTTLE, IP_THROTTLE)&.compact&.first
    headers = headers.merge(self.class.build(data)) if data
    headers = self.class.vary(headers) if api
    [ status, headers, body ]
  end
end
