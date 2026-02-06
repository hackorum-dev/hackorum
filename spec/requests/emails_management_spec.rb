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
      post settings_emails_path, params: { email: 'new-address@example.com', name: 'My New Name' }
      expect(response).to redirect_to(settings_account_path)
    end

    raw = extract_raw_token_from_mailer

    # Simulate user clicking verification link while logged out (no session).
    delete session_path

    get verification_path(token: raw)
    expect(response).to redirect_to(settings_account_path)

    new_alias = Alias.by_email('new-address@example.com').where(user_id: user.id).first
    expect(new_alias).to be_present
    expect(new_alias.name).to eq('My New Name')

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

  it 'requires name when adding a completely new email' do
    user = create(:user, password: 'secret', password_confirmation: 'secret')
    attach_verified_alias(user, email: 'me@example.com')

    sign_in(email: 'me@example.com')

    expect {
      post settings_emails_path, params: { email: 'brand-new@example.com' }
    }.not_to change { UserToken.count }

    expect(response).to redirect_to(settings_account_path)
    expect(flash[:alert]).to match(/provide a display name/)
  end

  it 'requires name when email is already verified by user' do
    user = create(:user, password: 'secret', password_confirmation: 'secret')
    attach_verified_alias(user, email: 'me@example.com')

    sign_in(email: 'me@example.com')

    expect {
      post settings_emails_path, params: { email: 'me@example.com' }
    }.not_to change { UserToken.count }

    expect(response).to redirect_to(settings_account_path)
    expect(flash[:alert]).to match(/already verified/)
  end

  it 'creates alias directly without verification when email is already verified by user' do
    user = create(:user, password: 'secret', password_confirmation: 'secret')
    attach_verified_alias(user, email: 'me@example.com')

    sign_in(email: 'me@example.com')

    expect {
      post settings_emails_path, params: { email: 'me@example.com', name: 'Alternative Name' }
    }.to change { Alias.by_email('me@example.com').count }.by(1)

    expect(UserToken.count).to eq(0) # No verification token created

    expect(response).to redirect_to(settings_account_path)
    expect(flash[:notice]).to eq('Alias added.')

    new_alias = Alias.by_email('me@example.com').find_by(name: 'Alternative Name')
    expect(new_alias).to be_present
    expect(new_alias.user_id).to eq(user.id)
    expect(new_alias.verified_at).to be_present
  end

  it 'creates additional alias with new name when associating existing aliases' do
    user = create(:user, password: 'secret', password_confirmation: 'secret')
    attach_verified_alias(user, email: 'me@example.com')

    # Legacy alias for another email
    create(:alias, email: 'legacy@example.com', name: 'Old Name')

    sign_in(email: 'me@example.com')

    perform_enqueued_jobs do
      post settings_emails_path, params: { email: 'legacy@example.com', name: 'New Name' }
      expect(response).to redirect_to(settings_account_path)
    end

    raw = extract_raw_token_from_mailer
    get verification_path(token: raw)
    expect(response).to redirect_to(settings_account_path)

    aliases = Alias.by_email('legacy@example.com').where(user_id: user.id)
    expect(aliases.count).to eq(2)
    expect(aliases.pluck(:name)).to contain_exactly('Old Name', 'New Name')
  end

  it 'does not create duplicate alias when name matches existing' do
    user = create(:user, password: 'secret', password_confirmation: 'secret')
    attach_verified_alias(user, email: 'me@example.com')

    # Legacy alias for another email
    create(:alias, email: 'legacy2@example.com', name: 'Existing Name')

    sign_in(email: 'me@example.com')

    perform_enqueued_jobs do
      post settings_emails_path, params: { email: 'legacy2@example.com', name: 'Existing Name' }
      expect(response).to redirect_to(settings_account_path)
    end

    raw = extract_raw_token_from_mailer
    get verification_path(token: raw)
    expect(response).to redirect_to(settings_account_path)

    aliases = Alias.by_email('legacy2@example.com').where(user_id: user.id)
    expect(aliases.count).to eq(1)
    expect(aliases.first.name).to eq('Existing Name')
  end

  describe 'alias removal' do
    it 'allows removing alias with no messages' do
      user = create(:user, password: 'secret', password_confirmation: 'secret')
      primary = attach_verified_alias(user, email: 'me@example.com')
      secondary = create(:alias, user: user, person: user.person, email: 'other@example.com', name: 'Other', verified_at: Time.current, sender_count: 0)

      sign_in(email: 'me@example.com')

      expect {
        delete settings_email_path(secondary)
      }.to change { Alias.count }.by(-1)

      expect(response).to redirect_to(settings_account_path)
      expect(flash[:notice]).to eq('Alias removed.')
      expect(Alias.find_by(id: secondary.id)).to be_nil
    end

    it 'blocks removing alias with sent messages' do
      user = create(:user, password: 'secret', password_confirmation: 'secret')
      primary = attach_verified_alias(user, email: 'me@example.com')
      secondary = create(:alias, user: user, person: user.person, email: 'other@example.com', name: 'Other', verified_at: Time.current, sender_count: 5)

      sign_in(email: 'me@example.com')

      expect {
        delete settings_email_path(secondary)
      }.not_to change { user.person.aliases.count }

      expect(response).to redirect_to(settings_account_path)
      expect(flash[:alert]).to match(/message history/)
    end

    it 'blocks removing alias with CC mentions' do
      user = create(:user, password: 'secret', password_confirmation: 'secret')
      primary = attach_verified_alias(user, email: 'me@example.com')
      secondary = create(:alias, user: user, person: user.person, email: 'other@example.com', name: 'Other', verified_at: Time.current, sender_count: 0)

      # Create a mention for this alias
      topic = create(:topic)
      message = create(:message, topic: topic)
      create(:mention, message: message, alias: secondary, person: user.person)

      sign_in(email: 'me@example.com')

      expect {
        delete settings_email_path(secondary)
      }.not_to change { user.person.aliases.count }

      expect(response).to redirect_to(settings_account_path)
      expect(flash[:alert]).to match(/message history/)
    end

    it 'blocks removing primary alias' do
      user = create(:user, password: 'secret', password_confirmation: 'secret')
      primary = attach_verified_alias(user, email: 'me@example.com')

      sign_in(email: 'me@example.com')

      expect {
        delete settings_email_path(primary)
      }.not_to change { user.person.aliases.count }

      expect(response).to redirect_to(settings_account_path)
      expect(flash[:alert]).to match(/primary alias/)
    end
  end

  def extract_raw_token_from_mailer
    mail = ActionMailer::Base.deliveries.last
    expect(mail).to be_present
    url = mail.body.encoded[%r{https?://[^\s]+}]
    Rack::Utils.parse_query(URI.parse(url).query)['token']
  end
end
