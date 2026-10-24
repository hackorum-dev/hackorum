require 'rails_helper'

RSpec.describe UserToken, type: :model do
  it 'issues and consumes a token' do
    token, raw = UserToken.issue!(purpose: 'register', email: 'user@example.com', ttl: 5.minutes)
    expect(token).to be_persisted
    found = UserToken.consume!(raw, purpose: 'register')
    expect(found).to eq(token)
    expect(found).to be_consumed
    # Second consume fails
    expect(UserToken.consume!(raw, purpose: 'register')).to be_nil
  end

  it 'lets only one of two concurrent holders consume' do
    token, = UserToken.issue!(purpose: 'register', email: 'user@example.com', ttl: 5.minutes)
    other = UserToken.find(token.id)
    token.consume!
    expect { other.consume! }.to raise_error(UserToken::AlreadyConsumed)
  end

  it 'rolls consumption back with the surrounding transaction' do
    token, raw = UserToken.issue!(purpose: 'register', email: 'user@example.com', ttl: 5.minutes)
    ActiveRecord::Base.transaction do
      token.consume!
      raise ActiveRecord::Rollback
    end
    expect(UserToken.find_usable(raw)).to eq(token)
  end
end
