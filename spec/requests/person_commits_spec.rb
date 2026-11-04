require 'rails_helper'

RSpec.describe 'Person commit activity', type: :request do
  let(:person) { create(:person) }
  let!(:person_alias) do
    al = create(:alias, person: person, name: 'Commit Person', email: 'commits@example.com')
    person.update!(default_alias_id: al.id)
    al
  end

  def credit(commit, role: 'author', to: person)
    create(:commit_person, commit: commit, person: to, role: role)
  end

  describe 'GET /person/:email/commits' do
    let!(:commit) do
      create(:commit, subject: 'Fix ruleutils.c dumping', branches: [ 'master' ],
                      committed_at: Time.zone.local(2024, 5, 10, 11))
    end

    before { credit(commit) }

    it 'renders the commit calendar in its own turbo frame' do
      get person_commits_path('commits@example.com')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('id="person-commit-activity"')
      expect(response.body).to include('contrib-calendar')
    end

    it 'is not swallowed by the person glob route' do
      expect(Rails.application.routes.recognize_path('/person/commits@example.com/commits'))
        .to include(controller: 'person_commits', action: 'show')
    end

    it 'defaults to the most recent year holding credits' do
      get person_commits_path('commits@example.com')

      expect(response.body).to include('Commits in 2024')
    end

    it 'ignores llm-sourced credits, in the list and the year selector' do
      other = create(:commit, subject: 'Guessed authorship', branches: [ 'master' ],
                              committed_at: Time.zone.local(2023, 5, 11, 11))
      create(:commit_person, commit: other, person: person, role: 'author', source: 'llm', confidence: 0.9)

      get person_commits_path('commits@example.com')

      expect(response.body).to include('Fix ruleutils.c dumping')
      expect(response.body).not_to include('Guessed authorship')
      expect(response.body).not_to include('>2023<')
    end

    it 'lists committer-sourced reviews marked committer without any feature' do
      other = create(:commit, subject: 'Committed for someone', branches: [ 'master' ],
                              committed_at: Time.zone.local(2023, 5, 13, 11))
      create(:commit_person, commit: other, person: person, role: 'reviewer', source: 'committer')

      get person_commits_path('commits@example.com', year: 2023)

      row = Nokogiri::HTML(response.body).css('table.commit-activity-table tbody tr').find { |tr| tr.text.include?('Committed for someone') }
      marker = row.at_css('td:first-child .activity-tag + .commit-credit-committer')
      expect(marker.text).to eq('committer')
      expect(marker.previous_element.text).to match(/review/i)
      box = Nokogiri::HTML(response.body).css('.summary-box').find { |b| b.at_css('.summary-box-label').text.match?(/review/i) }
      expect(box.at_css('.summary-box-sub').text).to eq('1 as committer')
    end

    context 'with the patchset_lineage feature' do
      let(:user) { create(:user) }

      before do
        create(:user_feature, user: user, feature: 'patchset_lineage')
        sign_in_as(user)
      end

      it 'lists llm-sourced credits marked LLM, in the list and the year selector' do
        other = create(:commit, subject: 'Guessed authorship', branches: [ 'master' ],
                                committed_at: Time.zone.local(2023, 5, 11, 11))
        create(:commit_person, commit: other, person: person, role: 'author', source: 'llm', confidence: 0.9)

        get person_commits_path('commits@example.com', year: 2023)

        expect(response.body).to include('Guessed authorship')
        expect(response.body).to include('>2023<')

        doc = Nokogiri::HTML(response.body)
        row = doc.css('table.commit-activity-table tbody tr').find { |tr| tr.text.include?('Guessed authorship') }
        marker = row.at_css('td:first-child .activity-tag + .commit-credit-llm')
        expect(marker.text).to eq('LLM')
        expect(marker['title']).to eq('Credited by LLM analysis, not a commit trailer')
        expect(marker.previous_element.text).to match(/author/i)
        expect(row.css('td:nth-child(2) .commit-credit-llm')).to be_empty
      end

      it 'marks only the llm role when the viewer also has a parsed role' do
        other = create(:commit, subject: 'Mixed credit', branches: [ 'master' ],
                                committed_at: Time.zone.local(2023, 5, 12, 11))
        create(:commit_person, commit: other, person: person, role: 'committer')
        create(:commit_person, commit: other, person: person, role: 'author', source: 'llm', confidence: 0.9)

        get person_commits_path('commits@example.com', year: 2023)

        row = Nokogiri::HTML(response.body).css('table.commit-activity-table tbody tr').find { |tr| tr.text.include?('Mixed credit') }
        tags = row.css('td:first-child .activity-tag')
        marked = tags.select { |t| t.next_element&.matches?('.commit-credit-llm') }
        expect(marked.map { |t| t.text.downcase }).to eq([ 'author' ])
        expect(tags.map { |t| t.text.downcase }).to include('committer')
        expect(row.css('.commit-credit-llm').size).to eq(1)
      end

      it 'leaves parsed credits unmarked' do
        get person_commits_path('commits@example.com')

        expect(response.body).to include('Fix ruleutils.c dumping')
        expect(response.body).not_to include('commit-credit-llm')
      end
    end

    it 'lists only years with commit credits in the year selector' do
      get person_commits_path('commits@example.com')

      expect(response.body).to include('>2024<')
      expect(response.body).not_to include('>2023<')
    end

    it 'labels calendar tooltips in commits' do
      get person_commits_path('commits@example.com')

      expect(response.body).to include('2024-05-10: 1 commit')
    end

    it 'scopes the calendar filter selector to its own frame' do
      get person_commits_path('commits@example.com')

      expect(response.body).to include('data-contrib-calendar-filter-selector-value="#person-commit-activity .activity-filters form"')
    end
  end

  describe 'drill-down routes' do
    let!(:commit) do
      create(:commit, subject: 'Tighten executor check', branches: [ 'master' ],
                      committed_at: Time.zone.local(2024, 5, 10, 11))
    end

    before { credit(commit) }

    it 'renders a single day' do
      get person_commit_activity_path('commits@example.com', '2024-05-10')

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Commits on May 10, 2024')
    end

    it 'renders a month' do
      get person_commit_monthly_activity_path('commits@example.com', 2024, 5)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Commits in May 2024')
    end

    it 'renders a week' do
      week = WeekCalculation.week_number(Date.new(2024, 5, 10), 2024, WeekCalculation::DEFAULT_WEEK_START)

      get person_commit_weekly_activity_path('commits@example.com', 2024, week)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Commits in week #{week}")
    end

    it 'renders a chosen year' do
      get person_commit_contributions_path('commits@example.com', year: 2024)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Commits in 2024')
    end
  end

  it 'renders for a person with no commit credits at all' do
    get person_commits_path('commits@example.com')

    expect(response).to have_http_status(:ok)
  end

  describe 'detail table' do
    let!(:master) do
      create(:commit, sha: 'abc12345def', subject: 'Fix ruleutils.c dumping',
                      branches: [ 'master' ], committer_name: 'Tom Lane',
                      committed_at: Time.zone.local(2024, 5, 10, 11))
    end
    let!(:backport) do
      create(:commit, sha: '999888777', subject: 'Fix ruleutils.c dumping',
                      branches: [ 'REL_17_STABLE' ], released_in: '17.6',
                      cherry_picked_from_sha: 'abc12345def',
                      committed_at: Time.zone.local(2024, 5, 11, 11))
    end
    let(:topic) { create(:topic, title: 'Re: pg_dump and rules') }

    before do
      credit(master, role: 'author')
      credit(backport, role: 'author')
      create(:commit_topic, commit: master, topic: topic)
    end

    it 'shows role tags, the backport marker and the commit link' do
      get person_commits_path('commits@example.com')

      expect(response.body).to include('Author')
      expect(response.body).to include('Backported')
      expect(response.body).to include('https://github.com/postgres/postgres/commit/abc12345def')
      expect(response.body).to include('Fix ruleutils.c dumping')
    end

    it 'shows the short sha and who committed it' do
      get person_commits_path('commits@example.com')

      expect(response.body).to include('abc12345')
      expect(response.body).to include('committed by Tom Lane')
    end

    it 'shows every branch with its release label' do
      get person_commits_path('commits@example.com')

      expect(response.body).to include('REL_17_STABLE')
      expect(response.body).to include('17.6')
    end

    it 'caps a runaway branch list rather than rendering thousands of badges' do
      12.times do |i|
        create(:commit, sha: "cap#{i}", subject: 'Fix ruleutils.c dumping',
                        branches: [ "REL_#{i}_STABLE" ], released_in: "#{i}.1",
                        cherry_picked_from_sha: 'abc12345def',
                        committed_at: Time.zone.local(2024, 5, 12, 11))
      end

      get person_commits_path('commits@example.com')

      doc = Nokogiri::HTML(response.body)
      row = doc.at_css('table.commit-activity-table tbody tr')
      expect(row.css('.commit-badge').size).to eq(8)
      expect(row.at_css('.commit-badge-more').text).to eq('+6 more')
    end

    it 'links the associated thread' do
      get person_commits_path('commits@example.com')

      expect(response.body).to include('Re: pg_dump and rules')
      expect(response.body).to include(topic_path(topic))
    end

    it 'counts the commit once and reports the backport in the summary' do
      get person_commits_path('commits@example.com')

      expect(response.body).to include('of which 1 backported')
      expect(response.body).to match(/summary-box-value">1<\/span><span class="summary-box-label">Author/)
    end

    it 'renders one row for the change, not one per branch' do
      get person_commits_path('commits@example.com')

      expect(response.body.scan('Fix ruleutils.c dumping').size).to eq(1)
    end

    it 'filters by role' do
      get person_commits_path('commits@example.com', roles: [ 'reviewer' ])

      expect(response.body).to include('No commit activity in this period.')
      expect(response.body).not_to include('Fix ruleutils.c dumping')
    end

    it 'renders a checkbox per tab role and none for tested_by' do
      get person_commits_path('commits@example.com')

      CommitActivity::ROLES.each do |role|
        expect(response.body).to include(%(value="#{role}"))
      end
      expect(response.body).not_to include('value="tested_by"')
    end

    it 'omits the committed-by line when the person committed it themselves' do
      credit(master, role: 'committer')

      get person_commits_path('commits@example.com')

      expect(response.body).not_to include('committed by Tom Lane')
    end

    it 'builds a single table row holding every cell' do
      get person_commits_path('commits@example.com')

      table = response.body[/<table class="activity-table commit-activity-table">(.*?)<\/table>/m, 1]
      rows = table.scan(/<tr>(.*?)<\/tr>/m).flatten.drop(1)
      expect(rows.size).to eq(1)
      expect(rows.first).to include('>Author<')
      expect(rows.first).to include('>Backported<')
      expect(rows.first).to include('commit/abc12345def')
      expect(rows.first).to include('>abc12345<')
      expect(rows.first).to include('master')
      expect(rows.first).to include('REL_17_STABLE')
      expect(rows.first).to include('May 10, 2024')
      expect(rows.first).to include('target="_blank"')
      expect(rows.first).to include('data-turbo-frame="_top"')
    end

    it 'keeps the person and the tab roles out of each other filter param' do
      get person_commits_path('commits@example.com')

      expect(response.body).to include('name="roles[]"')
      expect(response.body).not_to include('name="filters[]"')
    end
  end

  it 'says so when a commit has no linked thread' do
    commit = create(:commit, branches: [ 'master' ], committed_at: Time.zone.local(2024, 5, 10, 11))
    credit(commit)

    get person_commits_path('commits@example.com')

    expect(response.body).to include('No linked thread')
  end
end
