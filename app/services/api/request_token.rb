module Api
  # One lookup per request, shared by the rate limiter and the controllers.
  class RequestToken
    ENV_KEY = "hackorum.api_token"
    Result = Struct.new(:state, :token)

    def self.resolve(env)
      env[ENV_KEY] ||= lookup(env["HTTP_AUTHORIZATION"])
    end

    def self.lookup(header)
      return Result.new(:none) if header.blank?

      scheme, raw = header.split(" ", 2)
      token = ApiToken.authenticate(raw.to_s.strip) if scheme.to_s.casecmp?("bearer")
      token ? Result.new(:valid, token) : Result.new(:invalid)
    end
  end
end
