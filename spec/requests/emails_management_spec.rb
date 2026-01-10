require 'rails_helper'

RSpec.describe 'Emails management', type: :request do
  include ActiveJob::TestHelper

  before { clear_enqueued_jobs && ActionMailer::Base.deliveries.clear }

  def sign_in(email:, password: 'secret')
    post session_path, params: { email: email, password: password }
    expect(response).to redirect_to(root_path)
  end

  def attach_verified_alias(user, email:, primary: true)
    al = create(:alias, user: user, email: email)
    if primary && user.person&.default_alias_id.nil?
      user.person.update!(default_alias_id: al.id)
    end
    Alias.by_email(email).update_all(verified_at: Time.current)
    al
  end

  it 'sends verification for adding a new email and attaches on verify' do
    user = create(:user, password: 'secret', password_confirmation: 'secret')
    attach_verified_alias(user, email: 'me@example.com')

    sign_in(email: 'me@example.com')

    perform_enqueued_jobs do
      post settings_emails_path, params: { email: 'new-address@example.com' }
      expect(response).to redirect_to(settings_account_path)
    end

    raw = extract_raw_token_from_mailer

    # Simulate user clicking verification link while logged out (no session).
    delete session_path

    get verification_path(token: raw)
    expect(response).to redirect_to(settings_account_path)

    expect(Alias.by_email('new-address@example.com').where(user_id: user.id)).to exist

    post session_path, params: { email: 'new-address@example.com', password: 'secret' }
    expect(response).to redirect_to(root_path)
  end

  it 'blocks adding an email owned by another user' do
    other = create(:user)
    attach_verified_alias(other, email: 'taken@example.com')

    user = create(:user, password: 'secret', password_confirmation: 'secret')
    attach_verified_alias(user, email: 'me2@example.com')

    sign_in(email: 'me2@example.com')
    expect {
      post settings_emails_path, params: { email: 'taken@example.com' }
    }.not_to change { UserToken.count }
    expect(response).to redirect_to(settings_account_path)
  end

  it 'attaches all matching aliases when the email exists multiple times' do
    user = create(:user, password: 'secret', password_confirmation: 'secret')
    attach_verified_alias(user, email: 'me-multi@example.com')

    # Legacy duplicates for the same email (different names)
    create(:alias, email: 'multi@example.com', name: 'Old One')
    create(:alias, email: 'multi@example.com', name: 'Older One')

    sign_in(email: 'me-multi@example.com')

    perform_enqueued_jobs do
      post settings_emails_path, params: { email: 'multi@example.com' }
      expect(response).to redirect_to(settings_account_path)
    end

    raw = extract_raw_token_from_mailer
    get verification_path(token: raw)
    expect(response).to redirect_to(settings_account_path)

    aliases = Alias.by_email('multi@example.com')
    expect(aliases.count).to eq(2)
    expect(aliases.pluck(:user_id).uniq).to eq([user.id])
    expect(aliases.where(verified_at: nil)).to be_empty
  end

  it 'rejects verification when logged in as a different user than the token user' do
    token_user = create(:user, password: 'secret', password_confirmation: 'secret')
    attach_verified_alias(token_user, email: 'token-user@example.com')

    other_user = create(:user, password: 'secret', password_confirmation: 'secret')
    attach_verified_alias(other_user, email: 'other@example.com')

    # Simulate an existing verification token for token_user.
    token, raw = UserToken.issue!(purpose: 'add_alias', user: token_user, email: 'token-user@example.com', ttl: 1.hour)

    sign_in(email: 'other@example.com')

    get verification_path(token: raw)

    expect(response).to redirect_to(settings_account_path)
    expect(flash[:alert]).to match(/different user/)
    expect(Alias.by_email('token-user@example.com').pluck(:user_id).uniq).to eq([token_user.id])
  ensure
    token&.destroy
  end

  def extract_raw_token_from_mailer
    mail = ActionMailer::Base.deliveries.last
    expect(mail).to be_present
    url = mail.body.encoded[%r{https?://[^\s]+}]
    Rack::Utils.parse_query(URI.parse(url).query)['token']
  end
end
