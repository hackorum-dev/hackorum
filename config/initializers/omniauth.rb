OMNIAUTH_SETUP_PROC = ->(env) {
  send_mode = env["QUERY_STRING"].to_s.include?("send=1")
  strategy  = env["omniauth.strategy"]

  if send_mode
    strategy.options[:scope]       = OAuth::Scopes::SEND
    strategy.options[:access_type] = "offline"
    strategy.options[:prompt]      = "consent"
  else
    strategy.options[:scope]       = OAuth::Scopes::DEFAULT
    strategy.options[:access_type] = "online"
    strategy.options[:prompt]      = "select_account"
  end
}

Rails.application.config.middleware.use OmniAuth::Builder do
  provider :google_oauth2,
           ENV["GOOGLE_CLIENT_ID"],
           ENV["GOOGLE_CLIENT_SECRET"],
           setup: OMNIAUTH_SETUP_PROC
end

OmniAuth.config.allowed_request_methods = [ :post ]
