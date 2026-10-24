require 'rails_helper'

RSpec.describe 'Registration and Login', type: :request do
  include ActiveJob::TestHelper

  before { clear_enqueued_jobs && ActionMailer::Base.deliveries.clear }

  describe 'registration via existing alias' do
    it 'creates a user and attaches aliases on verification' do
      al = create(:alias, email: 'user@example.com', user: nil)

      perform_enqueued_jobs do
        post registration_path, params: { email: 'user@example.com', username: 'newuser', password: 'secret123', password_confirmation: 'secret123' }
        expect(response).to redirect_to(root_path)
      end

      raw = extract_raw_token_from_mailer
      get verification_path(token: raw)
      expect(response).to redirect_to(root_path)

      al.reload
      expect(al.user).to be_present
      expect(al.verified_at).to be_present
    end
  end

  describe 'registration for an email merged into another user' do
    it 'refuses to attach to the owning person' do
      owner = create(:user, username: 'owner')
      merged = create(:alias, email: 'old@example.com', person: owner.person, user: nil)

      post registration_path, params: { email: 'old@example.com', username: 'intruder', password: 'secret123', password_confirmation: 'secret123' }
      raw = extract_raw_token_from_mailer
      get verification_path(token: raw)

      expect(response).to redirect_to(new_session_path)
      expect(User.find_by(username: 'intruder')).not_to be_verified
      expect(merged.reload.person_id).to eq(owner.person_id)
      expect(merged.user_id).to be_nil
    end
  end

  describe 'registration via new alias' do
    it 'creates user and alias on verification' do
      perform_enqueued_jobs do
        post registration_path, params: { email: 'new@example.com', name: 'New Person', username: 'newperson', password: 'secret123', password_confirmation: 'secret123' }
        expect(response).to redirect_to(root_path)
      end

      raw = extract_raw_token_from_mailer
      get verification_path(token: raw)
      expect(response).to redirect_to(root_path)

      user = User.order(:created_at).last
      al = user.aliases.first
      expect(al).to be_present
      expect(al.email).to eq('new@example.com')
      expect(user.person.default_alias_id).to eq(al.id)
      expect(al.verified_at).to be_present
    end

    it 'creates an unverified user with username reservation on registration' do
      perform_enqueued_jobs do
        post registration_path, params: { email: 'new@example.com', name: 'New Person', username: 'reserved', password: 'secret123', password_confirmation: 'secret123' }
        expect(response).to redirect_to(root_path)
      end

      user = User.find_by(username: 'reserved')
      expect(user).to be_present
      expect(user).not_to be_verified
      expect(user.aliases).to be_empty
      reservation = NameReservation.find_by(name: 'reserved')
      expect(reservation.owner_type).to eq('User')
      expect(reservation.owner_id).to eq(user.id)
      expect(UserToken.find_by(user_id: user.id, purpose: 'register').email).to eq('new@example.com')
    end

    it 'verifies the user on token use' do
      perform_enqueued_jobs do
        post registration_path, params: { email: 'new@example.com', username: 'verifyme', password: 'secret123', password_confirmation: 'secret123' }
      end

      get verification_path(token: extract_raw_token_from_mailer)
      expect(response).to redirect_to(root_path)

      user = User.find_by(username: 'verifyme')
      expect(user).to be_verified
      expect(user.aliases.first.name).to eq('new@example.com')
    end

    it 'moves the user onto the archive person and drops the placeholder' do
      al = create(:alias, email: 'archived@example.com', user: nil)
      archive_person = al.person

      perform_enqueued_jobs do
        post registration_path, params: { email: 'archived@example.com', username: 'archived', password: 'secret123', password_confirmation: 'secret123' }
      end
      placeholder_id = User.find_by(username: 'archived').person_id
      expect(placeholder_id).not_to eq(archive_person.id)

      get verification_path(token: extract_raw_token_from_mailer)

      user = User.find_by(username: 'archived')
      expect(user.person_id).to eq(archive_person.id)
      expect(Person.exists?(placeholder_id)).to be(false)
    end

    it 'rejects verification when email got claimed meanwhile' do
      perform_enqueued_jobs do
        post registration_path, params: { email: 'claimed@example.com', username: 'late', password: 'secret123', password_confirmation: 'secret123' }
      end
      owner = create(:user)
      create(:alias, email: 'claimed@example.com', user: owner, person: owner.person)

      get verification_path(token: extract_raw_token_from_mailer)
      expect(response).to redirect_to(new_session_path)
      expect(User.find_by(username: 'late')).not_to be_verified
    end

    it 'rejects a username held by a pending registration' do
      perform_enqueued_jobs do
        post registration_path, params: { email: 'first@example.com', username: 'racetest', password: 'secret123', password_confirmation: 'secret123' }
        expect(response).to redirect_to(root_path)
      end

      perform_enqueued_jobs do
        post registration_path, params: { email: 'second@example.com', username: 'RaceTest', password: 'secret123', password_confirmation: 'secret123' }
        expect(response).to redirect_to(registration_path)
        expect(flash[:alert]).to match(/taken/i)
      end
    end

    [
      [ 'password mismatch', { password_confirmation: 'other' }, /confirmation/i ],
      [ 'blank password', { password: '', password_confirmation: '' }, /password can't be blank/i ],
      [ 'short password', { password: 'short', password_confirmation: 'short' }, /too short/i ],
      [ 'blank username', { username: '' }, /username can't be blank/i ],
      [ 'invalid username', { username: 'bad name!' }, /username is invalid/i ],
      [ 'reserved username', { username: 'global' }, /reserved/i ],
      [ 'invalid email', { email: 'nope' }, /valid email/i ]
    ].each do |label, override, message|
      it "rejects #{label} without creating records" do
        params = { email: 'x@example.com', username: 'someone', password: 'secret123', password_confirmation: 'secret123' }.merge(override)
        expect {
          post registration_path, params: params
        }.not_to change { [ User.count, Person.count, UserToken.count, NameReservation.count ] }
        expect(response).to redirect_to(registration_path)
        expect(flash[:alert]).to match(message)
      end
    end

    it 'does not treat unverified users as signed in' do
      perform_enqueued_jobs do
        post registration_path, params: { email: 'pending@example.com', username: 'pending', password: 'secret123', password_confirmation: 'secret123' }
      end
      expect(User.active.find_by(username: 'pending')).to be_nil
      expect(Person.registered.where(id: User.find_by(username: 'pending').person_id)).to be_empty
    end
  end

  describe 'token lifetime' do
    def register(email:, username:)
      perform_enqueued_jobs do
        post registration_path, params: { email: email, username: username, password: 'secret123', password_confirmation: 'secret123' }
      end
      extract_raw_token_from_mailer
    end

    it 'keeps the token usable when verification fails midway' do
      raw = register(email: 'flaky@example.com', username: 'flaky')

      allow(Alias).to receive(:create!).and_raise(ActiveRecord::RecordInvalid.new(Alias.new))
      get verification_path(token: raw)
      expect(flash[:alert]).to match(/could not complete/i)
      expect(User.find_by(username: 'flaky')).not_to be_verified
      expect(UserToken.find_usable(raw)).to be_present

      allow(Alias).to receive(:create!).and_call_original
      get verification_path(token: raw)
      expect(flash[:notice]).to match(/registration complete/i)
      expect(User.find_by(username: 'flaky')).to be_verified
    end

    it 'does not accept a token twice' do
      raw = register(email: 'twice@example.com', username: 'twice')
      get verification_path(token: raw)
      get verification_path(token: raw)
      expect(flash[:alert]).to match(/invalid or expired/i)
    end
  end

  describe 'resend verification' do
    before do
      perform_enqueued_jobs do
        post registration_path, params: { email: 'resend@example.com', username: 'resender', password: 'secret123', password_confirmation: 'secret123' }
      end
      @first_raw = extract_raw_token_from_mailer
      ActionMailer::Base.deliveries.clear
    end

    it 'renders the resend form and links to it' do
      get resend_verification_path
      expect(response).to have_http_status(:ok)
      get new_session_path
      expect(response.body).to include(resend_verification_path)
    end

    it 'sends a new working token and keeps the old one valid' do
      perform_enqueued_jobs do
        post resend_verification_path, params: { email: ' Resend@Example.com ' }
      end
      expect(response).to redirect_to(root_path)
      raw = extract_raw_token_from_mailer
      expect(raw).not_to eq(@first_raw)

      user = User.find_by(username: 'resender')
      token = UserToken.find_usable(raw)
      expect(token.expires_at).to be_within(1.second).of(user.created_at + User::UNVERIFIED_TTL)
      expect(UserToken.find_usable(@first_raw)).to be_present

      get verification_path(token: raw)
      expect(user.reload).to be_verified
      expect(UserToken.find_usable(@first_raw)).to be_present
      get verification_path(token: @first_raw)
      expect(flash[:alert]).to match(/invalid or expired/i)
    end

    it 'answers the same for unknown emails without sending mail' do
      perform_enqueued_jobs do
        post resend_verification_path, params: { email: 'nobody@example.com' }
      end
      expect(response).to redirect_to(root_path)
      expect(flash[:notice]).to match(/if a pending registration exists/i)
      expect(ActionMailer::Base.deliveries).to be_empty
    end

    it 'does not resend for verified users' do
      get verification_path(token: @first_raw)
      perform_enqueued_jobs do
        post resend_verification_path, params: { email: 'resend@example.com' }
      end
      expect(ActionMailer::Base.deliveries).to be_empty
    end

    it 'does not resend past the cleanup deadline' do
      User.find_by(username: 'resender').update_columns(created_at: 4.days.ago)
      perform_enqueued_jobs do
        post resend_verification_path, params: { email: 'resend@example.com' }
      end
      expect(ActionMailer::Base.deliveries).to be_empty
    end
  end

  describe 'password login' do
    it 'signs in with verified alias and password' do
      user = create(:user, password: 'secret', password_confirmation: 'secret')
      al = create(:alias, user: user, email: 'login@example.com')
      user.person.update!(default_alias_id: al.id) if user.person.default_alias_id.nil?
      Alias.by_email('login@example.com').update_all(verified_at: Time.current)

      post session_path, params: { email: 'login@example.com', password: 'secret' }
      expect(response).to redirect_to(root_path)
    end
  end

  def extract_raw_token_from_mailer
    mail = ActionMailer::Base.deliveries.last
    expect(mail).to be_present
    url = mail.body.encoded[%r{https?://[^\s]+}]
    Rack::Utils.parse_query(URI.parse(url).query)['token']
  end
end
