require 'rails_helper'

RSpec.describe 'Account deletion', type: :request do
  let!(:user) { create(:user, password: 'secret', password_confirmation: 'secret') }
  let!(:team) { create(:team) }

  before do
    create(:alias, user: user, person: user.person, email: 'me@example.com', verified_at: Time.current)
    create(:team_member, team: team, user: user, role: 'admin')
    create(:identity, user: user, refresh_token: 'r-tok')
    post session_path, params: { email: 'me@example.com', password: 'secret' }
    expect(response).to redirect_to(root_path)
  end

  it 'drops team memberships and revokes google grants' do
    allow(Net::HTTP).to receive(:post_form).and_return(double(code: '200', body: ''))

    post settings_deletion_path, params: { confirmation: 'DELETE' }

    expect(response).to redirect_to(root_path)
    expect(TeamMember.where(user_id: user.id)).to be_empty
    expect(Net::HTTP).to have_received(:post_form).with(URI('https://oauth2.googleapis.com/revoke'), token: 'r-tok')
  end
end
