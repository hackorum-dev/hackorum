require "rails_helper"

RSpec.describe Stats::Period::Committers do
  let(:now) { Time.zone.parse("2026-11-06 12:00") }
  let!(:fx) { build_stats_release_fixture }
  let(:data) { described_class.new(Stats::Period::Release.new(19)).to_h }

  before { travel_to(now) }

  def row(name) = data[:rows].find { |r| r[:name] == name }

  def nonzero(series)
    labels = data[:monthly][:buckets]
    series.to_h { |s| [ s[:label], labels.zip(s[:values]).reject { |_, v| v.zero? }.to_h ] }
  end

  it "compares the committers" do
    expect(data[:rows].map { |r| r[:name] }).to eq(%w[Alice Dave])
    expect(row("Alice").except(:id, :email)).to eq(name: "Alice", since: nil, commits: 3, own: 1, for_others: 2, authors: 2, reverts: 1, lines: 130,
                                                   reviewed_for_others: 0, judged: 2, as_posted: 2, alone: 1, messages: 1, threads: 1, people: 1, backported: 1)
    expect(row("Dave").except(:id, :email)).to eq(name: "Dave", since: Time.zone.parse("2026-02-01 12:00"), commits: 1, own: 1, for_others: 0, authors: 0, reverts: 0, lines: 20,
                                                  reviewed_for_others: 0, judged: 0, as_posted: 0, alone: 0, messages: 0, threads: 0, people: 0, backported: 1)
  end

  it "builds the chart inputs" do
    expect(data[:change][:categories]).to eq(%w[Alice])
    expect(data[:change][:series].map { |s| [ s[:label], s[:values] ] }).to eq([ [ "as posted", [ 100 ] ], [ "split from a series", [ 0 ] ], [ "light", [ 0 ] ], [ "moderate", [ 0 ] ],
                                                                                 [ "significant", [ 0 ] ], [ "from discussion", [ 0 ] ] ])
    expect(data[:change][:series].last[:gray]).to be(true)
    expect(data[:lines_chart][:series].map { |s| s[:values] }).to eq([ [ 10, 20 ], [ 120, 0 ] ])
    expect(data[:reviews_chart][:categories]).to eq(%w[Alice Dave])
  end

  it "shows split and from-discussion verdicts as their own bars, committers without an assessed commit left out" do
    CommitVerdict.find_by!(commit: fx.commits[:c4]).update!(verdict: "partial")
    expect(data[:change][:categories]).to eq(%w[Alice])
    expect(data[:change][:series].map { |s| [ s[:label], s[:values] ] }).to eq([ [ "as posted", [ 50 ] ], [ "split from a series", [ 50 ] ], [ "light", [ 0 ] ],
                                                                                 [ "moderate", [ 0 ] ], [ "significant", [ 0 ] ], [ "from discussion", [ 0 ] ] ])
  end

  it "rounds the from-discussion bar so the split sums to exactly 100" do
    CommitVerdict.find_by!(commit: fx.commits[:c4]).update!(verdict: "from_discussion")
    commit = create(:commit, committed_at: Time.zone.parse("2026-03-01 12:00"), branches: %w[REL_19_STABLE master])
    create(:commit_person, commit: commit, person: fx.people["alice"], role: CommitPerson::COMMITTER, raw_name: "Alice", raw_email: "alice@example.com")
    create(:commit_person, commit: commit, person: fx.people["bob"], role: "author", raw_name: "Bob", raw_email: "bob@example.com")
    CommitterReviewer.sync!([ commit.id ])
    topic = create(:topic, title: "t5", creator_alias: fx.people["bob"].default_alias, created_at: Time.zone.parse("2026-02-01"))
    create(:commit_topic, commit: commit, topic: topic)
    run = create(:patchset_run, topic: topic)
    create(:commit_verdict, patchset_run: run, topic: topic, commit: commit, verdict: "modified", change_level: "light", source_message: nil, confidence: 1.0,
                            reviewers_final: 0, reviewers_earlier: 0, reviewers_none: 0, reviews: [])
    expect(row("Alice")[:judged]).to eq(3)
    expect(data[:change][:series].map { |s| s[:values].first }).to eq([ 33, 0, 33, 0, 0, 34 ])
  end

  it "builds the monthly series" do
    expect(nonzero(data[:monthly][:commits])).to eq("Alice" => { "Oct 2025" => 1, "Jan 2026" => 1, "Jul 2026" => 1 }, "Dave" => { "Feb 2026" => 1 }, "other committers" => {})
    expect(nonzero(data[:monthly][:authored])).to eq("Alice" => { "Jan 2026" => 1 }, "Dave" => { "Feb 2026" => 1, "Jul 2026" => 1 }, "other committers" => {})
    expect(nonzero(data[:monthly][:reviewed])).to eq("other committers" => {})
    expect(data[:monthly][:authored].map { |s| s[:label] }).to eq([ "Dave", "Alice", "other committers" ])
    expect(nonzero(data[:monthly][:messages])).to eq("Alice" => { "Dec 2025" => 1 }, "other committers" => {})
    expect(data[:monthly][:commits].map { |s| s[:fold] }).to eq([ false, false, true ])
  end

  it "does not credit the committer when only an llm author exists" do
    commit = create(:commit, committed_at: Time.zone.parse("2026-03-01 12:00"), branches: %w[REL_19_STABLE master])
    create(:commit_person, commit: commit, person: fx.people["alice"], role: CommitPerson::COMMITTER, raw_name: "Alice", raw_email: "alice@example.com")
    create(:commit_person, commit: commit, person: nil, role: "author", source: "llm", raw_name: "Nobody", raw_email: "nobody@example.com")
    expect(nonzero(data[:monthly][:commits])["Alice"]).to include("Mar 2026" => 1)
    expect(nonzero(data[:monthly][:authored])["Alice"]).to eq("Jan 2026" => 1)
    expect(row("Alice")[:authors]).to eq(2)
  end

  it "credits the committer when the only llm author is the committer" do
    commit = create(:commit, committed_at: Time.zone.parse("2026-03-01 12:00"), branches: %w[REL_19_STABLE master])
    create(:commit_person, commit: commit, person: fx.people["alice"], role: CommitPerson::COMMITTER, raw_name: "Alice", raw_email: "alice@example.com")
    create(:commit_person, commit: commit, person: fx.people["alice"], role: "author", source: "llm", raw_name: "Alice", raw_email: "alice@example.com")
    expect(nonzero(data[:monthly][:authored])["Alice"]).to eq("Jan 2026" => 1, "Mar 2026" => 1)
  end
end
