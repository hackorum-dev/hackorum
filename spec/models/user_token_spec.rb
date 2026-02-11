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
end
