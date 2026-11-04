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
    create(:team_member, team: team, user: create(:user), role: 'admin')
    allow(Net::HTTP).to receive(:post_form).and_return(double(code: '200', body: ''))

    post settings_deletion_path, params: { confirmation: 'DELETE' }

    expect(response).to redirect_to(root_path)
    expect(TeamMember.where(user_id: user.id)).to be_empty
    expect(Net::HTTP).to have_received(:post_form).with(URI('https://oauth2.googleapis.com/revoke'), token: 'r-tok')
  end

  it 'drops the person when nothing in the archive refers to it' do
    allow(Net::HTTP).to receive(:post_form).and_return(double(code: '200', body: ''))
    person = user.person
    create(:team_member, team: team, user: create(:user), role: 'admin')

    post settings_deletion_path, params: { confirmation: 'DELETE' }

    expect(user.reload.person_id).to be_nil
    expect(Person.exists?(person.id)).to be false
  end

  it 'refuses when the user is the only admin of a team' do
    create(:team_member, team: team, user: create(:user), role: 'member')

    post settings_deletion_path, params: { confirmation: 'DELETE' }

    expect(response).to redirect_to(settings_deletion_path)
    expect(flash[:alert]).to include(team.name)
    expect(user.reload.deleted_at).to be_nil
  end
end
