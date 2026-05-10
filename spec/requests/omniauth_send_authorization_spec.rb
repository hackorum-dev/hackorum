require 'rails_helper'

RSpec.describe 'Send authorization callback', type: :request do
  let(:user) { create(:user, admin: true) }

  before do
    OmniAuth.config.test_mode = true
    sign_in_as(user)

    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: 'google_oauth2',
      uid: 'g-uid-1',
      info:    { email: 'alice@gmail.com', name: 'Alice' },
      credentials: {
        token: 'a-tok',
        refresh_token: 'r-tok',
        expires_at: 1.hour.from_now.to_i
      }
    )
    Rails.application.env_config['omniauth.auth'] =
      OmniAuth.config.mock_auth[:google_oauth2]
    Rails.application.env_config['omniauth.params'] = { 'send' => '1' }
  end

  def trigger_callback
    get '/auth/google_oauth2?send=1'
    follow_redirect!
  end

  it 'persists tokens on identity' do
    trigger_callback
    identity = user.reload.identities.find_by(uid: 'g-uid-1')
    expect(identity).to be_present
    expect(identity.refresh_token).to eq('r-tok')
    expect(identity.access_token).to eq('a-tok')
    expect(identity.access_token_expires_at).to be_within(2.seconds).of(1.hour.from_now)
    expect(identity.send_authorized_at).not_to be_nil
    expect(identity.send_revoked_at).to be_nil
    expect(identity.last_send_error).to be_nil
  end

  it 'auto-verifies the matching alias' do
    trigger_callback
    al = user.reload.aliases.find_by(email: 'alice@gmail.com')
    expect(al).to be_present
    expect(al.verified_at).not_to be_nil
  end

  it 'redirects to settings_account_path with a notice' do
    trigger_callback
    expect(response).to redirect_to(settings_account_path)
    follow_redirect!
    expect(flash[:notice]).to be_present
  end

  it 'rejects when not signed in' do
    allow_any_instance_of(ApplicationController).to receive(:current_user).and_return(nil)
    allow_any_instance_of(ApplicationController).to receive(:user_signed_in?).and_return(false)
    trigger_callback
    expect(response).to redirect_to(new_session_path)
  end

  it 'rejects non-admin users' do
    non_admin = create(:user)
    sign_in_as(non_admin)
    trigger_callback
    expect(response).to redirect_to(settings_account_path)
    expect(non_admin.reload.identities).to be_empty
  end

  it 'records the granted scope on the identity' do
    trigger_callback
    identity = user.reload.identities.find_by(uid: 'g-uid-1')
    expect(identity.scopes).to include('gmail.send')
  end

  it 'does not store the refresh_token in raw_info' do
    get '/auth/google_oauth2?send=1'
    follow_redirect!
    identity = user.reload.identities.find_by(uid: 'g-uid-1')
    expect(identity.raw_info).not_to include('r-tok')
    expect(identity.raw_info).not_to include('a-tok')
    expect(identity.raw_info).to include('alice@gmail.com')  # info still preserved
  end
end
