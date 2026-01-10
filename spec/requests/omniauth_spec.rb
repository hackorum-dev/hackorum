require 'rails_helper'

RSpec.describe 'OmniAuth Google', type: :request do
  def sign_in_with_password(email:, password: 'secret')
    post session_path, params: { email: email, password: password }
    expect(response).to redirect_to(root_path)
  end

  def sign_in_with_google(link: false)
    path = link ? "/auth/google_oauth2?link=1" : "/auth/google_oauth2"
    get path
    follow_redirect!
  end

  def sign_out
    delete session_path
  end

  def attach_verified_alias(user, email:, primary: true)
    al = create(:alias, user: user, email: email)
    if primary && user.person&.default_alias_id.nil?
      user.person.update!(default_alias_id: al.id)
    end
    Alias.by_email(email).update_all(verified_at: Time.current)
  end

  it 'creates a new user on google sign-in with a new email' do
    mock_google_oauth(uid: 'uid-new', email: 'new@example.com')

    expect {
      sign_in_with_google
    }.to change(User, :count).by(1)
      .and change(Identity, :count).by(1)

    expect(response).to redirect_to(root_path)

    identity = Identity.last
    alias_record = Alias.by_email('new@example.com').first
    expect(identity).to be_present
    expect(alias_record).to be_present
    expect(alias_record.user_id).to eq(identity.user_id)
    expect(identity.user.person.default_alias_id).to eq(alias_record.id)
    expect(alias_record.verified_at).to be_present
  end

  it 'attaches an existing unclaimed alias on google sign-in' do
    unclaimed = create(:alias, user: nil, email: 'legacy@example.com')
    mock_google_oauth(uid: 'uid-legacy', email: 'legacy@example.com')

    expect {
      sign_in_with_google
    }.to change(User, :count).by(1)
      .and change(Identity, :count).by(1)

    expect(response).to redirect_to(root_path)

    unclaimed.reload
    expect(unclaimed.user_id).to eq(Identity.last.user_id)
    expect(unclaimed.verified_at).to be_present
  end

  it 'rejects google sign-in when the email belongs to an existing user' do
    user = create(:user, password: 'secret', password_confirmation: 'secret')
    attach_verified_alias(user, email: 'owned@example.com')
    mock_google_oauth(uid: 'uid-owned', email: 'owned@example.com')

    expect {
      sign_in_with_google
    }.not_to change(Identity, :count)

    expect(response).to redirect_to(new_session_path)
    expect(flash[:alert]).to match(/link it from settings/i)
  end

  it 'links a google account from settings and allows future google sign-in' do
    user = create(:user, password: 'secret', password_confirmation: 'secret')
    attach_verified_alias(user, email: 'me@example.com')
    sign_in_with_password(email: 'me@example.com')
    mock_google_oauth(uid: 'uid-link', email: 'linkme@example.com')
    expect {
      sign_in_with_google(link: true)
    }.to change(Identity, :count).by(1)

    expect(response).to redirect_to(settings_account_path)
    identity = Identity.last
    expect(identity.user_id).to eq(user.id)
    expect(Alias.by_email('linkme@example.com').where(user_id: user.id)).to exist

    sign_out
    sign_in_with_password(email: 'me@example.com')
    sign_out

    mock_google_oauth(uid: 'uid-link', email: 'linkme@example.com')
    sign_in_with_google
    expect(response).to redirect_to(root_path)
    expect(Identity.find_by(uid: 'uid-link')&.user_id).to eq(user.id)
  end

  it 'shows a notice when linking an already connected google account' do
    user = create(:user, password: 'secret', password_confirmation: 'secret')
    attach_verified_alias(user, email: 'me5@example.com')
    sign_in_with_password(email: 'me5@example.com')

    mock_google_oauth(uid: 'uid-dup', email: 'dup@example.com')
    sign_in_with_google(link: true)
    expect(response).to redirect_to(settings_account_path)

    mock_google_oauth(uid: 'uid-dup', email: 'dup@example.com')
    sign_in_with_google(link: true)
    expect(response).to redirect_to(settings_account_path)
    expect(flash[:notice]).to match(/already linked to your account/i)
  end

  it 'links a google account that matches an unclaimed alias' do
    user = create(:user, password: 'secret', password_confirmation: 'secret')
    attach_verified_alias(user, email: 'me2@example.com')
    unclaimed = create(:alias, user: nil, email: 'unclaimed@example.com')
    sign_in_with_password(email: 'me2@example.com')
    mock_google_oauth(uid: 'uid-unclaimed', email: 'unclaimed@example.com')
    expect {
      sign_in_with_google(link: true)
    }.to change(Identity, :count).by(1)

    expect(response).to redirect_to(settings_account_path)
    unclaimed.reload
    expect(unclaimed.user_id).to eq(user.id)
    expect(unclaimed.verified_at).to be_present
  end

  it 'links a google account that matches an existing user alias' do
    user = create(:user, password: 'secret', password_confirmation: 'secret')
    attach_verified_alias(user, email: 'me3@example.com')
    owned = create(:alias, user: user, email: 'owned@example.com')
    sign_in_with_password(email: 'me3@example.com')
    mock_google_oauth(uid: 'uid-owned-link', email: 'owned@example.com')
    expect {
      sign_in_with_google(link: true)
    }.to change(Identity, :count).by(1)

    expect(response).to redirect_to(settings_account_path)
    owned.reload
    expect(owned.user_id).to eq(user.id)
    expect(owned.verified_at).to be_present
  end

  it 'rejects linking when the email belongs to another user' do
    other = create(:user)
    attach_verified_alias(other, email: 'taken@example.com')

    user = create(:user, password: 'secret', password_confirmation: 'secret')
    attach_verified_alias(user, email: 'me4@example.com')
    sign_in_with_password(email: 'me4@example.com')
    mock_google_oauth(uid: 'uid-taken', email: 'taken@example.com')
    expect {
      sign_in_with_google(link: true)
    }.not_to change(Identity, :count)

    expect(response).to redirect_to(settings_account_path)
    expect(flash[:alert]).to match(/linked to another account/i)
  end

  it 'lets an oauth-created user link an additional google account' do
    mock_google_oauth(uid: 'uid-primary', email: 'first@example.com')
    sign_in_with_google
    expect(response).to redirect_to(root_path)
    user = Identity.find_by(uid: 'uid-primary').user

    mock_google_oauth(uid: 'uid-secondary', email: 'second@example.com')
    expect {
      sign_in_with_google(link: true)
    }.to change(Identity, :count).by(1)

    expect(response).to redirect_to(settings_account_path)
    expect(Identity.find_by(uid: 'uid-secondary')&.user_id).to eq(user.id)
    expect(Alias.by_email('second@example.com').where(user_id: user.id)).to exist

    sign_out
    mock_google_oauth(uid: 'uid-secondary', email: 'second@example.com')
    sign_in_with_google
    expect(response).to redirect_to(root_path)
  end
end
