require 'rails_helper'

RSpec.describe 'Session invalidation', type: :request do
  let!(:user) { create(:user, password: 'oldsecret', password_confirmation: 'oldsecret') }

  before do
    create(:alias, user: user, person: user.person, email: 'me@example.com', verified_at: Time.current)
    post session_path, params: { email: 'me@example.com', password: 'oldsecret' }
    expect(response).to redirect_to(root_path)
  end

  it 'drops sessions created before a password change elsewhere' do
    get settings_account_path
    expect(response).to have_http_status(:ok)

    user.update!(password: 'changedsecret', password_confirmation: 'changedsecret')

    get settings_account_path
    expect(response).to redirect_to(new_session_path)
  end

  it 'keeps the session that changed the password' do
    patch settings_update_current_password_path, params: { current_password: 'oldsecret', password: 'newsecret1', password_confirmation: 'newsecret1' }
    expect(response).to redirect_to(settings_password_path)

    get settings_account_path
    expect(response).to have_http_status(:ok)
  end
end
