require 'rails_helper'

RSpec.describe 'Malformed params', type: :request do
  let!(:topic) { create(:topic, last_message_at: 1.day.ago) }
  let!(:message) { create(:message, topic: topic, created_at: 1.day.ago) }

  it 'ignores an unparseable viewing_since' do
    get topics_path(viewing_since: 'abc')
    expect(response).to have_http_status(:ok)

    get topics_path(viewing_since: '2024-99-99')
    expect(response).to have_http_status(:ok)
  end

  it 'ignores an unparseable search cursor' do
    get search_topics_path(q: 'foo', cursor: 'x_1')
    expect(response).to have_http_status(:ok)

    get search_topics_path(q: 'foo', cursor: '2024-99-99_1')
    expect(response).to have_http_status(:ok)
  end

  it 'clamps longpage' do
    get search_topics_path(q: 'foo', longpage: -1)
    expect(response).to have_http_status(:ok)

    get search_topics_path(q: 'foo', longpage: 10**20)
    expect(response).to have_http_status(:ok)
  end

  it 'returns 404 for impossible report periods' do
    get monthly_report_path(year: 2024, month: 13)
    expect(response).to have_http_status(:not_found)

    get weekly_report_path(year: 2024, week: 60)
    expect(response).to have_http_status(:not_found)

    get weekly_report_path(year: 9999, week: 1)
    expect(response).to have_http_status(:not_found)
  end

  it 'returns 404 for impossible profile months' do
    al = create(:alias, email: 'someone@example.com')
    get person_monthly_activity_path(email: al.email, year: 2024, month: 13)
    expect(response).to have_http_status(:not_found)
  end

  it 'accepts a single string filter' do
    al = create(:alias, email: 'someone@example.com')
    get person_path(email: al.email, filters: 'started_thread')
    expect(response).to have_http_status(:ok)
  end

  it 'does not resolve team templates against private teams' do
    user = create(:user)
    sign_in_as(user)
    team = create(:team, name: 'secret-team', visibility: :private)
    template = create(:saved_search, scope: 'team', team: nil, query: 'title:{{team_name}}')

    get search_topics_path(saved_search_id: template.id, team_id: team.id)
    expect(response).to have_http_status(:not_found)
    expect(response.body).not_to include('secret-team')
  end
end
