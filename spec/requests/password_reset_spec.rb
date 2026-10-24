require 'rails_helper'

RSpec.describe 'Password reset', type: :request do
  include ActiveJob::TestHelper

  before { clear_enqueued_jobs && ActionMailer::Base.deliveries.clear }

  it 'resets password via emailed token' do
    user = create(:user, password: 'oldsecret', password_confirmation: 'oldsecret')
    al = create(:alias, user: user, email: 'reset@example.com')
    user.person.update!(default_alias_id: al.id) if user.person.default_alias_id.nil?
    Alias.by_email('reset@example.com').update_all(verified_at: Time.current)

    perform_enqueued_jobs do
      post password_path, params: { email: 'reset@example.com' }
      expect(response).to redirect_to(new_session_path)
    end

    raw = extract_raw_token_from_mailer
    get edit_password_path(token: raw)
    expect(response).to have_http_status(:ok)

    patch password_path, params: { token: raw, password: 'newsecret', password_confirmation: 'newsecret' }
    expect(response).to redirect_to(new_session_path)

    post session_path, params: { email: 'reset@example.com', password: 'newsecret' }
    expect(response).to redirect_to(root_path)
  end

  it 'keeps the token usable after a failed update' do
    user = create(:user, password: 'oldsecret', password_confirmation: 'oldsecret')
    _, raw = UserToken.issue!(purpose: 'reset_password', user: user, email: 'x@example.com', ttl: 30.minutes)

    patch password_path, params: { token: raw, password: 'newsecret', password_confirmation: 'typo' }
    expect(response).to have_http_status(:unprocessable_content)
    expect(user.reload.authenticate('oldsecret')).to be_truthy
    expect(UserToken.find_usable(raw)).to be_present

    patch password_path, params: { token: raw, password: 'newsecret', password_confirmation: 'newsecret' }
    expect(response).to redirect_to(new_session_path)
    expect(user.reload.authenticate('newsecret')).to be_truthy

    patch password_path, params: { token: raw, password: 'other', password_confirmation: 'other' }
    expect(response).to redirect_to(new_password_path)
    expect(user.reload.authenticate('newsecret')).to be_truthy
  end

  it 'invalidates other reset tokens once one is used' do
    user = create(:user, password: 'oldsecret', password_confirmation: 'oldsecret')
    _, first = UserToken.issue!(purpose: 'reset_password', user: user, email: 'x@example.com', ttl: 30.minutes)
    _, second = UserToken.issue!(purpose: 'reset_password', user: user, email: 'x@example.com', ttl: 30.minutes)

    patch password_path, params: { token: first, password: 'newsecret', password_confirmation: 'newsecret' }
    expect(response).to redirect_to(new_session_path)
    expect(UserToken.find_usable(second, purpose: 'reset_password')).to be_nil
  end

  it 'rejects edit with an invalid token' do
    get edit_password_path(token: 'bogus')
    expect(response).to redirect_to(new_password_path)
  end

  def extract_raw_token_from_mailer
    mail = ActionMailer::Base.deliveries.last
    expect(mail).to be_present
    url = mail.body.encoded[%r{https?://[^\s]+}]
    Rack::Utils.parse_query(URI.parse(url).query)['token']
  end
end
