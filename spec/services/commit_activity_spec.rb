require "rails_helper"

RSpec.describe CommitActivity do
  let(:person) { create(:person) }
  let(:year) { 2026 }
  let(:year_range) { Date.new(year, 1, 1)..Date.new(year, 12, 31) }

  def activity(roles: described_class::ROLES, ids: [ person.id ])
    described_class.new(person_ids: ids, year: year, roles: roles)
  end

  describe "backport collapsing" do
    let!(:master) do
      create(:commit, sha: "aaa111", subject: "Fix ruleutils.c",
                      branches: [ "master" ], committed_at: Time.zone.local(year, 3, 14, 10))
    end
    let!(:rel18) do
      create(:commit, sha: "bbb222", subject: "Fix ruleutils.c",
                      branches: [ "REL_18_STABLE" ], released_in: "18.2",
                      cherry_picked_from_sha: "aaa111",
                      committed_at: Time.zone.local(year, 3, 15, 9))
    end
    let!(:rel17) do
      create(:commit, sha: "ccc333", subject: "Fix ruleutils.c",
                      branches: [ "REL_17_STABLE" ], released_in: "17.6",
                      cherry_picked_from_sha: "aaa111",
                      committed_at: Time.zone.local(year, 3, 15, 9, 30))
    end

    before do
      [ master, rel18, rel17 ].each do |commit|
        create(:commit_person, commit: commit, person: person, role: "author")
      end
    end

    it "produces a single row dated by the master commit" do
      rows = activity.detail_rows_in(year_range)

      expect(rows.size).to eq(1)
      expect(rows.first[:commit].sha).to eq("aaa111")
      expect(rows.first[:committed_on]).to eq(Date.new(year, 3, 14))
    end

    it "carries every branch and flags the row as backported" do
      row = activity.detail_rows_in(year_range).first

      expect(row[:branches].map { |b| b[:branch] }).to eq(%w[master REL_18_STABLE REL_17_STABLE])
      expect(row[:branches].map { |b| b[:released_label] }).to eq([ "unreleased", "18.2", "17.6" ])
      expect(row[:backported]).to be(true)
    end

    it "counts the change once on the calendar" do
      expect(activity.daily_counts).to eq({ Date.new(year, 3, 14) => 1 })
    end

    it "counts the change as backported in the summary" do
      expect(activity.summary_in(year_range)[:backported]).to eq(1)
    end
  end

  it "keeps a stable-branch-only original as its own row" do
    commit = create(:commit, branches: [ "REL_17_STABLE" ], released_in: "17.6",
                             cherry_picked_from_sha: nil,
                             committed_at: Time.zone.local(year, 6, 1, 12))
    create(:commit_person, commit: commit, person: person, role: "committer")

    rows = activity.detail_rows_in(year_range)

    expect(rows.size).to eq(1)
    expect(rows.first[:branches].map { |b| b[:branch] }).to eq([ "REL_17_STABLE" ])
    expect(rows.first[:backported]).to be(false)
    expect(activity.summary_in(year_range)[:backported]).to eq(0)
  end

  it "carries the discussion topics linked to the commit" do
    commit = create(:commit, branches: [ "master" ], committed_at: Time.zone.local(year, 8, 4, 9))
    create(:commit_person, commit: commit, person: person, role: "author")
    topic = create(:topic)
    create(:commit_topic, commit: commit, topic: topic)

    expect(activity.detail_rows_in(year_range).first[:topics]).to eq([ topic ])
  end

  describe "roles" do
    let!(:commit) do
      create(:commit, branches: [ "master" ], committed_at: Time.zone.local(year, 4, 2, 8))
    end

    it "collapses several roles on one commit into one row counted once" do
      create(:commit_person, commit: commit, person: person, role: "author")
      create(:commit_person, commit: commit, person: person, role: "committer")

      subject_activity = activity
      rows = subject_activity.detail_rows_in(year_range)
      summary = subject_activity.summary_in(year_range)

      expect(rows.size).to eq(1)
      expect(rows.first[:roles]).to eq(%w[author committer])
      expect(summary[:total]).to eq(1)
      expect(summary[:author]).to eq(1)
      expect(summary[:committer]).to eq(1)
      expect(summary[:reviewer]).to eq(0)
    end

    it "ignores a commit credited only as tested_by" do
      create(:commit_person, commit: commit, person: person, role: "tested_by")

      expect(activity.detail_rows_in(year_range)).to be_empty
      expect(activity.daily_counts).to be_empty
    end

    it "narrows both the table and the calendar when filtered" do
      create(:commit_person, commit: commit, person: person, role: "reviewer")
      other = create(:commit, branches: [ "master" ], committed_at: Time.zone.local(year, 4, 3, 8))
      create(:commit_person, commit: other, person: person, role: "author")

      reviewer_only = activity(roles: %w[reviewer])

      expect(reviewer_only.detail_rows_in(year_range).map { |r| r[:commit].id }).to eq([ commit.id ])
      expect(reviewer_only.daily_counts).to eq({ Date.new(year, 4, 2) => 1 })
    end

    it "returns nothing when no role is selected" do
      create(:commit_person, commit: commit, person: person, role: "author")

      expect(activity(roles: []).detail_rows_in(year_range)).to be_empty
    end
  end

  describe "period slicing" do
    before do
      [ [ 2, 10 ], [ 5, 20 ], [ 5, 21 ] ].each do |month, day|
        commit = create(:commit, branches: [ "master" ], committed_at: Time.zone.local(year, month, day, 9))
        create(:commit_person, commit: commit, person: person, role: "author")
      end
    end

    it "slices a month out of the loaded year without another credit query" do
      subject_activity = activity
      subject_activity.detail_rows_in(year_range)

      may = Date.new(year, 5, 1)..Date.new(year, 5, 31)
      queries = captured_queries { expect(subject_activity.detail_rows_in(may).size).to eq(2) }

      expect(queries).to be_empty
    end

    it "counts only the sliced period in the summary" do
      february = Date.new(year, 2, 1)..Date.new(year, 2, 28)

      expect(activity.summary_in(february)[:total]).to eq(1)
    end
  end

  describe "two changes on one day" do
    it "adds them up on the calendar" do
      2.times do |i|
        commit = create(:commit, branches: [ "master" ], committed_at: Time.zone.local(year, 9, 9, 8 + i))
        create(:commit_person, commit: commit, person: person, role: "author")
      end

      expect(activity.daily_counts).to eq({ Date.new(year, 9, 9) => 2 })
    end

    it "orders the later commit first" do
      early = create(:commit, sha: "eee111", branches: [ "master" ],
                              committed_at: Time.zone.local(year, 9, 9, 8))
      late = create(:commit, sha: "fff222", branches: [ "master" ],
                             committed_at: Time.zone.local(year, 9, 9, 17))
      [ early, late ].each { |c| create(:commit_person, commit: c, person: person, role: "author") }

      shas = activity.detail_rows_in(year_range).map { |row| row[:commit].sha }
      expect(shas).to eq(%w[fff222 eee111])
    end

    it "breaks an identical timestamp by sha, higher first" do
      same_time = Time.zone.local(year, 9, 10, 8)
      %w[aaa000 zzz999].each do |sha|
        commit = create(:commit, sha: sha, branches: [ "master" ], committed_at: same_time)
        create(:commit_person, commit: commit, person: person, role: "author")
      end

      shas = activity.detail_rows_in(year_range).map { |row| row[:commit].sha }
      expect(shas).to eq(%w[zzz999 aaa000])
    end
  end

  it "loads the whole week grid, not just january to december" do
    grid_start = WeekCalculation.year_weeks_range(year, WeekCalculation::DEFAULT_WEEK_START).first
    expect(grid_start).to be < Date.new(year, 1, 1)

    commit = create(:commit, branches: [ "master" ], committed_at: grid_start.to_time + 9.hours)
    create(:commit_person, commit: commit, person: person, role: "author")

    expect(activity.daily_counts[grid_start]).to eq(1)
  end

  it "shifts the loaded window with a non-default week start" do
    sunday_start = WeekCalculation.year_weeks_range(year, 0).first
    expect(sunday_start).to be < WeekCalculation.year_weeks_range(year, WeekCalculation::DEFAULT_WEEK_START).first

    commit = create(:commit, branches: [ "master" ], committed_at: sunday_start.to_time + 9.hours)
    create(:commit_person, commit: commit, person: person, role: "author")

    sunday_activity = described_class.new(person_ids: [ person.id ], year: year, wday_start: 0)

    expect(activity.daily_counts).to be_empty
    expect(sunday_activity.daily_counts[sunday_start]).to eq(1)
  end

  describe "several credited people" do
    let(:other_person) { create(:person) }

    it "returns one row listing every credited person with their own roles" do
      commit = create(:commit, branches: [ "master" ], committed_at: Time.zone.local(year, 7, 7, 9))
      create(:commit_person, commit: commit, person: person, role: "committer")
      create(:commit_person, commit: commit, person: other_person, role: "author")
      create(:commit_person, commit: commit, person: other_person, role: "reviewer")

      team_activity = activity(ids: [ person.id, other_person.id ])
      rows = team_activity.detail_rows_in(year_range)

      expect(rows.size).to eq(1)
      expect(team_activity.summary_in(year_range)[:total]).to eq(1)

      credits = rows.first[:member_credits].index_by { |credit| credit[:person].id }
      expect(credits[person.id][:roles]).to eq(%w[committer])
      expect(credits[other_person.id][:roles]).to eq(%w[author reviewer])
    end

    it "lists a role once when two people share it" do
      commit = create(:commit, branches: [ "master" ], committed_at: Time.zone.local(year, 7, 8, 9))
      create(:commit_person, commit: commit, person: person, role: "author")
      create(:commit_person, commit: commit, person: other_person, role: "author")

      rows = activity(ids: [ person.id, other_person.id ]).detail_rows_in(year_range)

      expect(rows.first[:roles]).to eq(%w[author])
      expect(rows.first[:member_credits].size).to eq(2)
    end
  end

  describe ".available_years" do
    it "lists years with canonical credits, newest first" do
      [ 2019, 2024, 2024 ].each do |commit_year|
        commit = create(:commit, branches: [ "master" ], committed_at: Time.zone.local(commit_year, 5, 5, 9))
        create(:commit_person, commit: commit, person: person, role: "author")
      end
      backport = create(:commit, branches: [ "REL_15_STABLE" ], cherry_picked_from_sha: "nosuchsha",
                                 committed_at: Time.zone.local(2016, 1, 1, 9))
      create(:commit_person, commit: backport, person: person, role: "author")

      expect(described_class.available_years([ person.id ])).to eq([ 2024, 2019 ])
    end

    it "is empty without people" do
      expect(described_class.available_years([])).to eq([])
    end

    it "widens to llm credits only when asked" do
      commit = create(:commit, branches: [ "master" ], committed_at: Time.zone.local(2023, 5, 5, 9))
      create(:commit_person, commit: commit, person: person, role: "author", source: "llm", confidence: 0.9)

      expect(described_class.available_years([ person.id ])).to eq([])
      expect(described_class.available_years([ person.id ], sources: %w[parsed llm])).to eq([ 2023 ])
    end
  end

  describe "sources" do
    let!(:parsed_commit) do
      create(:commit, sha: "abc123", subject: "Parsed", branches: [ "master" ], committed_at: Time.zone.local(year, 2, 1, 9))
    end
    let!(:llm_commit) do
      create(:commit, sha: "def456", subject: "Guessed", branches: [ "master" ], committed_at: Time.zone.local(year, 3, 1, 9))
    end

    before do
      create(:commit_person, commit: parsed_commit, person: person, role: "author")
      create(:commit_person, commit: llm_commit, person: person, role: "author", source: "llm", confidence: 0.9)
    end

    it "reads parsed credits only by default" do
      rows = activity.detail_rows_in(year_range)

      expect(rows.map { |row| row[:commit].subject }).to eq([ "Parsed" ])
      expect(rows.first[:llm_roles]).to eq([])
    end

    it "flags llm-only roles when widened" do
      rows = described_class.new(person_ids: [ person.id ], year: year, sources: %w[parsed llm]).detail_rows_in(year_range)

      expect(rows.map { |row| [ row[:commit].subject, row[:llm_roles] ] }).to eq([ [ "Guessed", [ "author" ] ], [ "Parsed", [] ] ])
      expect(rows.first[:member_credits].first[:llm_roles]).to eq([ "author" ])
    end

    it "flags only the llm role when the same person has a parsed role on the commit" do
      create(:commit_person, commit: llm_commit, person: person, role: "committer")

      rows = described_class.new(person_ids: [ person.id ], year: year, sources: %w[parsed llm]).detail_rows_in(year_range)

      expect(rows.first[:roles]).to eq(%w[author committer])
      expect(rows.first[:llm_roles]).to eq([ "author" ])
    end

    it "does not flag a role that also has a parsed credit" do
      create(:commit_person, commit: llm_commit, person: person, role: "author", source: "parsed")

      rows = described_class.new(person_ids: [ person.id ], year: year, sources: %w[parsed llm]).detail_rows_in(year_range)

      expect(rows.first[:llm_roles]).to eq([])
    end
  end
end
