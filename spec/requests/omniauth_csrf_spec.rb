require 'rails_helper'

RSpec.describe 'OmniAuth request phase CSRF', type: :request do
  before do
    @validation = OmniAuth.config.request_validation_phase
    OmniAuth.config.request_validation_phase = OmniAuth::RailsCsrfProtection::TokenVerifier.new
    @forgery = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
  end

  after do
    ActionController::Base.allow_forgery_protection = @forgery
    OmniAuth.config.request_validation_phase = @validation
  end

  def button_token(action)
    form = Nokogiri::HTML(response.body).at_css(%(form[action="#{action}"]))
    form.at_css('input[name="authenticity_token"]')['value']
  end

  it 'accepts the token rendered into the sign-in button' do
    mock_google_oauth(uid: 'uid-csrf', email: 'csrf@example.com')
    get new_session_path
    post '/auth/google_oauth2', params: { authenticity_token: button_token('/auth/google_oauth2') }
    expect(response.location).not_to include('/auth/failure')
  end

  it 'rejects a missing token' do
    post '/auth/google_oauth2'
    expect(response.location).to include('InvalidAuthenticityToken')
  end
end
