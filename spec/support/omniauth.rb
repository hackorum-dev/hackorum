require 'omniauth'

module OmniauthHelpers
  def mock_google_oauth(uid:, email:, name: 'Test User')
    auth_hash = OmniAuth::AuthHash.new(
      provider: 'google_oauth2',
      uid: uid,
      info: {
        email: email,
        name: name
      }
    )
    OmniAuth.config.mock_auth[:google_oauth2] = auth_hash
    @omniauth_auth_hash = auth_hash
    Rails.application.env_config['omniauth.auth'] = auth_hash
    auth_hash
  end

  def omniauth_auth_hash
    @omniauth_auth_hash
  end
end

RSpec.configure do |config|
  config.include OmniauthHelpers, type: :request

  config.before(:each, type: :request) do
    OmniAuth.config.test_mode = true
    @omniauth_request_validation = OmniAuth.config.request_validation_phase
    OmniAuth.config.request_validation_phase = nil
  end

  config.after(:each, type: :request) do
    OmniAuth.config.mock_auth[:google_oauth2] = nil
    @omniauth_auth_hash = nil
    Rails.application.env_config['omniauth.auth'] = nil
    Rails.application.env_config['omniauth.params'] = nil
    OmniAuth.config.request_validation_phase = @omniauth_request_validation
  end
end
