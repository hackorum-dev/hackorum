require 'rails_helper'

RSpec.describe CleanupUnverifiedUsersJob do
  def pending_user(username, created_at:)
    user = User.create!(person: Person.new, username: username, created_at: created_at)
    UserToken.issue!(purpose: 'register', user: user, email: "#{username}@example.com", ttl: User::UNVERIFIED_TTL)
    user
  end

  it 'removes stale unverified users with their tokens, reservation and person' do
    stale = pending_user('stale', created_at: 4.days.ago)
    person_id = stale.person_id

    described_class.new.perform

    expect(User.exists?(stale.id)).to be(false)
    expect(Person.exists?(person_id)).to be(false)
    expect(UserToken.where(user_id: stale.id)).to be_empty
    expect(NameReservation.find_by(name: 'stale')).to be_nil
  end

  it 'keeps recent unverified and verified users' do
    fresh = pending_user('fresh', created_at: 1.day.ago)
    verified = create(:user, username: 'old', created_at: 1.year.ago)

    described_class.new.perform

    expect(User.exists?(fresh.id)).to be(true)
    expect(User.exists?(verified.id)).to be(true)
  end

  it 'removes expired tokens' do
    user = create(:user)
    UserToken.issue!(purpose: 'reset_password', user: user, email: 'a@example.com', ttl: -2.days)
    live, = UserToken.issue!(purpose: 'reset_password', user: user, email: 'a@example.com', ttl: 1.hour)

    described_class.new.perform

    expect(UserToken.pluck(:id)).to eq([ live.id ])
  end
end
