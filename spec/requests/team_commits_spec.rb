require 'rails_helper'

RSpec.describe 'Team commit activity', type: :request do
  def sign_in(email:, password: 'secret')
    post session_path, params: { email: email, password: password }
    expect(response).to redirect_to(root_path)
  end

  def attach_verified_alias(user, email:, name: 'Member')
    al = create(:alias, user: user, email: email, name: name)
    user.person.update!(default_alias_id: al.id) if user.person&.default_alias_id.nil?
    Alias.by_email(email).update_all(verified_at: Time.current)
    al
  end

  let!(:team) { create(:team, name: 'commit-team') }
  let!(:member) { create(:user, password: 'secret', password_confirmation: 'secret') }
  let!(:second_member) { create(:user, password: 'secret', password_confirmation: 'secret') }
  let!(:non_member) { create(:user, password: 'secret', password_confirmation: 'secret') }

  before do
    create(:team_member, team: team, user: member, role: 'admin')
    create(:team_member, team: team, user: second_member, role: 'member')
  end

  describe 'visibility on the new routes' do
    it 'redirects anonymous visitors to sign in' do
      get team_commits_path('commit-team')

      expect(response).to redirect_to(new_session_path)
    end

    it 'returns 404 for a signed-in non-member' do
      attach_verified_alias(non_member, email: 'outsider@example.com')
      sign_in(email: 'outsider@example.com')

      get team_commits_path('commit-team')

      expect(response).to have_http_status(:not_found)
    end

    it 'renders for a member' do
      attach_verified_alias(member, email: 'member@example.com')
      sign_in(email: 'member@example.com')

      get team_commits_path('commit-team')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="team-commit-activity"')
      expect(response.body).to include('contrib-calendar')
    end

    it 'guards every drill-down route, not just show' do
      week = WeekCalculation.week_number(Date.new(2024, 5, 10), 2024, WeekCalculation::DEFAULT_WEEK_START)

      [
        team_commit_activity_path('commit-team', '2024-05-10'),
        team_commit_monthly_activity_path('commit-team', 2024, 5),
        team_commit_weekly_activity_path('commit-team', 2024, week),
        team_commit_contributions_path('commit-team', year: 2024)
      ].each do |path|
        get path
        expect(response).to redirect_to(new_session_path)
      end
    end

    it '404s every drill-down route for a signed-in non-member' do
      attach_verified_alias(non_member, email: 'outsider@example.com')
      sign_in(email: 'outsider@example.com')
      week = WeekCalculation.week_number(Date.new(2024, 5, 10), 2024, WeekCalculation::DEFAULT_WEEK_START)

      [
        team_commit_activity_path('commit-team', '2024-05-10'),
        team_commit_monthly_activity_path('commit-team', 2024, 5),
        team_commit_weekly_activity_path('commit-team', 2024, week),
        team_commit_contributions_path('commit-team', year: 2024)
      ].each do |path|
        get path
        expect(response).to have_http_status(:not_found), "expected 404 for #{path}"
      end
    end

    it 'keeps the plain team profile route intact' do
      expect(Rails.application.routes.recognize_path('/team/commit-team/commits'))
        .to include(controller: 'team_commits', action: 'show')
      expect(Rails.application.routes.recognize_path('/team/commit-team'))
        .to include(controller: 'teams_profile', action: 'show')
    end
  end

  describe 'credited members column' do
    let!(:commit) do
      create(:commit, subject: 'Widen the executor check', branches: [ 'master' ],
                      committed_at: Time.zone.local(2024, 5, 10, 11))
    end

    before do
      attach_verified_alias(member, email: 'first@example.com', name: 'First Member')
      attach_verified_alias(second_member, email: 'second@example.com', name: 'Second Member')
      create(:commit_person, commit: commit, person: member.person, role: 'committer')
      create(:commit_person, commit: commit, person: second_member.person, role: 'author')
      create(:commit_person, commit: commit, person: second_member.person, role: 'reviewer')
      sign_in(email: 'first@example.com')
    end

    it 'lists both members on one row and counts the commit once' do
      get team_commits_path('commit-team')

      expect(response.body).to include('Credited members')
      expect(response.body.scan('Widen the executor check').size).to eq(1)

      doc = Nokogiri::HTML(response.body)
      rows = doc.css('table.commit-activity-table tbody tr')
      expect(rows.size).to eq(1)

      credits = rows.first.css('td .commit-member-credit')
      expect(credits.size).to eq(2)

      # one tuple per member: separate per-attribute lists would still pass if
      # the tags were paired with the wrong member
      pairings = credits.map do |credit|
        [
          credit.at_css('.activity-sender-name').text.strip,
          credit.css('.commit-role-tags .activity-tag').map { |tag| tag.text.strip },
          credit.at_css('a.activity-sender')['href'],
          credit.at_css('img.activity-sender-avatar')&.[]('alt')
        ]
      end

      expect(pairings).to contain_exactly(
        [ 'First Member', [ 'Committer' ], person_path('first@example.com'), 'First Member' ],
        [ 'Second Member', [ 'Author', 'Reviewer' ], person_path('second@example.com'), 'Second Member' ]
      )
    end

    it 'lists llm-sourced credits marked LLM' do
      other = create(:commit, subject: 'Guessed authorship', branches: [ 'master' ],
                              committed_at: Time.zone.local(2024, 5, 11, 11))
      create(:commit_person, commit: other, person: member.person, role: 'author', source: 'llm', confidence: 0.9)

      get team_commits_path('commit-team')

      doc = Nokogiri::HTML(response.body)
      rows = doc.css('table.commit-activity-table tbody tr')
      expect(rows.size).to eq(2)

      guessed = rows.find { |tr| tr.text.include?('Guessed authorship') }
      marker = guessed.at_css('.commit-role-tags .activity-tag + .commit-credit-llm')
      expect(marker.text).to eq('LLM')
      expect(marker.previous_element.text).to match(/author/i)
      expect(guessed.css('td:nth-child(2) .commit-credit-llm')).to be_empty
      parsed = rows.find { |tr| tr.text.include?('Widen the executor check') }
      expect(parsed.at_css('.commit-credit-llm')).to be_nil
    end

    it 'counts the shared commit once in the summary total' do
      get team_commits_path('commit-team')

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css('.summary-group-total').text.squish).to start_with('1 commit')
    end
  end

  describe 'the team profile page' do
    before do
      attach_verified_alias(member, email: 'member@example.com')
      sign_in(email: 'member@example.com')
    end

    it 'shows both tabs with email active' do
      get team_profile_path('commit-team')

      doc = Nokogiri::HTML(response.body)
      tabs = doc.css('nav.profile-tabs button.profile-tab')
      expect(tabs.map { |t| t.text.strip }).to eq([ 'Email activity', 'Commit activity' ])
      expect(tabs.first['class']).to include('is-active')
      expect(tabs.first['aria-selected']).to eq('true')
      expect(tabs.last['class'].to_s).not_to include('is-active')
    end

    it 'defers the commit frame' do
      get team_profile_path('commit-team')

      doc = Nokogiri::HTML(response.body)
      frame = doc.at_css('turbo-frame#team-commit-activity')
      expect(frame).to be_present
      expect(frame['src']).to eq(team_commits_path('commit-team'))
      expect(frame['loading']).to eq('lazy')
      expect(frame.children.map(&:text).join.strip).to eq('')
    end

    it 'renders the commit tab eagerly when it is the active tab' do
      get team_profile_path('commit-team', tab: 'commits')

      doc = Nokogiri::HTML(response.body)
      tabs = doc.css('nav.profile-tabs button.profile-tab')
      expect(tabs.last['class']).to include('is-active')
      expect(doc.at_css('turbo-frame#team-commit-activity')['loading']).to be_nil
    end
  end
end
