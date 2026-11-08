require "rails_helper"

RSpec.describe Stats::Period::Pulse do
  let(:now) { Time.zone.parse("2026-11-06 12:00") }
  let!(:fx) { build_stats_release_fixture }
  let(:pulse) { described_class.new(Stats::Period::Release.new(19), gran: "month").to_h }

  before { travel_to(now) }

  def strip(key) = pulse[:strips].find { |s| s[:key] == key }

  def nonzero(values)
    pulse[:buckets].map { |b| b[:label] }.zip(values).reject { |_, v| v.zero? }.to_h
  end

  it "carries the chart structure" do
    expect(pulse[:gran]).to eq("month")
    expect(pulse[:buckets].size).to eq(19)
    expect(pulse[:strips].map { |s| s[:key] }).to eq(Stats::PulseParams::ALL_KEYS)
    expect(pulse[:windows]).to eq([
      { from: "2025-05-05T20:00:00Z", to: "2025-09-22T20:00:00Z", phase: "early" },
      { from: "2025-09-22T20:00:00Z", to: "2026-06-01T20:00:00Z", phase: "middle" },
      { from: "2026-06-01T20:00:00Z", to: "2026-11-06T12:00:00Z", phase: "late" }
    ])
    expect(pulse[:events].first).to eq(at: "2025-09-22T20:00:00Z", label: "18.0 GA")
  end

  it "counts commits by author, split by committer status at the time" do
    s = strip("commits")
    expect(s[:split]).to be(true)
    expect(nonzero(s[:committers])).to eq("Jan 2026" => 1, "Feb 2026" => 1, "Jul 2026" => 1)
    expect(nonzero(s[:others])).to eq("Oct 2025" => 1)
  end

  it "does not give an unresolved author's commit to the committer" do
    commit = create(:commit, committed_at: Time.zone.parse("2026-03-01 12:00"), branches: %w[REL_19_STABLE master])
    create(:commit_person, commit: commit, person: fx.people["alice"], role: CommitPerson::COMMITTER, raw_name: "Alice", raw_email: "alice@example.com")
    create(:commit_person, commit: commit, person: nil, role: "author", raw_name: "Nobody", raw_email: "nobody@example.com")
    s = strip("commits")
    expect(nonzero(s[:committers])).to eq("Jan 2026" => 1, "Feb 2026" => 1, "Jul 2026" => 1)
    expect(nonzero(s[:others])).to eq("Oct 2025" => 1, "Mar 2026" => 1)
  end

  it "puts a commit with only an llm author in others" do
    commit = create(:commit, committed_at: Time.zone.parse("2026-03-01 12:00"), branches: %w[REL_19_STABLE master])
    create(:commit_person, commit: commit, person: fx.people["alice"], role: CommitPerson::COMMITTER, raw_name: "Alice", raw_email: "alice@example.com")
    create(:commit_person, commit: commit, person: nil, role: "author", source: "llm", raw_name: "Nobody", raw_email: "nobody@example.com")
    s = strip("commits")
    expect(nonzero(s[:committers])).to eq("Jan 2026" => 1, "Feb 2026" => 1, "Jul 2026" => 1)
    expect(nonzero(s[:others])).to eq("Oct 2025" => 1, "Mar 2026" => 1)
  end

  it "prefers a parsed author over an earlier llm author row" do
    commit = create(:commit, committed_at: Time.zone.parse("2026-03-01 12:00"), branches: %w[REL_19_STABLE master])
    create(:commit_person, commit: commit, person: nil, role: "author", source: "llm", raw_name: "Nobody", raw_email: "nobody@example.com")
    create(:commit_person, commit: commit, person: fx.people["dave"], role: "author", raw_name: "Dave", raw_email: "dave@example.com")
    create(:commit_person, commit: commit, person: fx.people["alice"], role: CommitPerson::COMMITTER, raw_name: "Alice", raw_email: "alice@example.com")
    s = strip("commits")
    expect(nonzero(s[:committers])).to eq("Jan 2026" => 1, "Feb 2026" => 1, "Mar 2026" => 1, "Jul 2026" => 1)
    expect(nonzero(s[:others])).to eq("Oct 2025" => 1)
  end

  it "gives a commit to the committer when the llm author is the committer" do
    commit = create(:commit, committed_at: Time.zone.parse("2026-03-01 12:00"), branches: %w[REL_19_STABLE master])
    create(:commit_person, commit: commit, person: fx.people["alice"], role: "author", source: "llm", raw_name: "Alice", raw_email: "alice@example.com")
    create(:commit_person, commit: commit, person: fx.people["alice"], role: CommitPerson::COMMITTER, raw_name: "Alice", raw_email: "alice@example.com")
    s = strip("commits")
    expect(nonzero(s[:committers])).to eq("Jan 2026" => 1, "Feb 2026" => 1, "Mar 2026" => 1, "Jul 2026" => 1)
    expect(nonzero(s[:others])).to eq("Oct 2025" => 1)
  end

  it "counts messages with the phase rule" do
    s = strip("messages")
    expect(nonzero(s[:committers])).to eq("Dec 2025" => 1)
    expect(nonzero(s[:others])).to eq("Sep 2025" => 3, "Oct 2025" => 2, "Dec 2025" => 1, "Mar 2026" => 1)
  end

  it "counts new threads, patch submissions and active people" do
    expect(nonzero(strip("new_threads")[:committers])).to eq("Dec 2025" => 1, "Jun 2026" => 1)
    expect(nonzero(strip("new_threads")[:others])).to eq("Sep 2025" => 1)
    expect(nonzero(strip("patch_submissions")[:committers])).to eq({})
    expect(nonzero(strip("patch_submissions")[:others])).to eq("Sep 2025" => 1, "Oct 2025" => 2)
    expect(nonzero(strip("active_people")[:committers])).to eq("Dec 2025" => 1)
    # bob posts in Sep 2025 in both the early and the middle window: counted once
    expect(nonzero(strip("active_people")[:others])).to eq("Sep 2025" => 2, "Oct 2025" => 1, "Dec 2025" => 1, "Mar 2026" => 1)
  end

  it "leaves commit notification threads out" do
    list = create(:mailing_list, identifier: "pgsql-committers", display_name: "committers", hidden_by_default: true)
    notice = create(:topic, title: "pgsql: Fix thing", creator_alias: fx.people["alice"].default_alias, created_at: Time.zone.parse("2026-02-10 10:00"))
    create(:topic_mailing_list, topic: notice, mailing_list: list)
    create(:message, topic: notice, sender_alias: fx.people["alice"].default_alias, created_at: Time.zone.parse("2026-02-10 10:00"))
    expect(nonzero(strip("messages")[:committers])).to eq("Dec 2025" => 1)
    expect(nonzero(strip("new_threads")[:committers])).to eq("Dec 2025" => 1, "Jun 2026" => 1)
    expect(nonzero(strip("active_people")[:committers])).to eq("Dec 2025" => 1)
  end

  it "counts first-time posters and landing threads without a split" do
    expect(strip("first_time_posters")[:split]).to be(false)
    expect(nonzero(strip("first_time_posters")[:values])).to eq("Sep 2025" => 1, "Dec 2025" => 1)
    expect(nonzero(strip("threads_landing")[:values])).to eq("Oct 2025" => 1, "Jan 2026" => 1, "Jul 2026" => 1)
  end

  it "buckets by week too" do
    weekly = described_class.new(Stats::Period::Release.new(19), gran: "week").to_h
    expect(weekly[:buckets].size).to eq(79)
    others = weekly[:strips].find { |s| s[:key] == "messages" }[:others]
    counts = weekly[:buckets].map { |b| b[:label] }.zip(others).reject { |_, v| v.zero? }.to_h
    expect(counts).to include("2025-09-01" => 1, "2025-09-08" => 1)
  end

  it "renders a year as one middle window with its events" do
    data = described_class.new(Stats::Period::Year.new(2025), gran: "month").to_h
    expect(data[:buckets].size).to eq(12)
    expect(data[:buckets].map { |b| b[:phase] }.uniq).to eq([ :middle ])
    expect(data[:windows]).to eq([ { from: "2025-01-01T00:00:00Z", to: "2026-01-01T00:00:00Z", phase: "middle" } ])
    expect(data[:events].map { |e| e[:label] }).to eq([ "18 branched (beta1)", "18.0 GA" ])
    messages = data[:strips].find { |s| s[:key] == "messages" }
    expect(messages[:committers].sum + messages[:others].sum).to eq(8)
  end
end
