require "rails_helper"

RSpec.describe Stats::Release::Person do
  let(:now) { Time.zone.parse("2026-11-06 12:00") }
  let!(:fx) { build_stats_release_fixture }
  let(:release) { Stats::Release.new(19) }
  let(:overview) { Stats::Release::Overview.new(release).to_h }

  before { travel_to(now) }

  def pick(data, strip)
    labels = data[:pulse][:buckets].map { |b| b[:label] }
    labels.zip(data[:pulse][:strips].find { |s| s[:key] == strip }[:values]).reject { |_, v| v.zero? }.to_h
  end

  context "a committer" do
    let(:data) { described_class.new(release, fx.people["alice"], overview: overview).to_h }

    it "describes the person" do
      expect(data[:person]).to eq(id: fx.people["alice"].id, name: "Alice", email: "alice@example.com", committer: true, committer_since: nil, company: "Acme")
    end

    it "fills the code band" do
      code = data[:code]
      expect(code[:commits]).to eq(value: 3, rank: 1, of: 2)
      expect(code[:own]).to eq(value: 1, share: 33, release: 50, better: nil)
      expect(code[:for_others]).to eq(value: 2, authors: 2)
      expect(code[:reviewed_for_others]).to eq(0)
      expect(code[:reverts]).to eq(value: 1, share: 33, release: 25, better: "down")
      expect(code[:lines]).to eq(added: 112, removed: 18, rank: 1, of: 2)
    end

    it "counts a commit whose only author row is an llm row naming the committer as own" do
      commit = create(:commit, committed_at: Time.zone.parse("2026-03-04 12:00"), branches: %w[REL_19_STABLE master])
      alice = fx.people["alice"]
      create(:commit_person, commit: commit, person: alice, role: CommitPerson::COMMITTER, raw_name: "Alice", raw_email: "alice@example.com")
      create(:commit_person, commit: commit, person: alice, role: "author", source: "llm", raw_name: "Alice", raw_email: "alice@example.com")
      CommitterReviewer.sync!([ commit.id ])
      expect(data[:code][:commits][:value]).to eq(4)
      expect(data[:code][:own]).to include(value: 2)
      expect(data[:code][:for_others][:value]).to eq(2)
    end

    it "keeps a thread with a later previous-major cherry-pick as started" do
      create(:commit_topic, commit: fx.commits[:c4c], topic: fx.topics[:t4])
      expect(data[:discussion][:threads_started]).to include(value: 2, landed: 2)
    end

    it "does not count commit notification threads as started" do
      list = create(:mailing_list, identifier: Stats::Release::Scopes::NOTICE_LIST, display_name: "comitters")
      notice = create(:topic, title: "pgsql: Fix thing", creator_alias: fx.people["alice"].default_alias, created_at: Time.zone.parse("2026-02-10 10:00"))
      create(:topic_mailing_list, topic: notice, mailing_list: list)
      create(:message, topic: notice, sender_alias: fx.people["alice"].default_alias, created_at: Time.zone.parse("2026-02-10 10:00"))
      expect(data[:discussion][:threads_started]).to eq(value: 2, landed: 2, landed_share: 100, release: 75, better: nil)
    end

    it "fills the discussion band" do
      d = data[:discussion]
      expect(d[:messages]).to eq(value: 1, rank: 2, of: 3)
      expect(d[:threads_started]).to eq(value: 2, landed: 2, landed_share: 100, release: 75, better: nil)
      expect(d[:started_after_branch]).to eq(value: 1, landed: 1)
      expect(d[:people_talked_to]).to eq(value: 1, committers: 0, others: 1)
      expect(d[:thread_age]).to eq(value: 40, release: 40, better: nil)
      expect(d[:versions]).to eq(value: 3.0, release: 3.0, better: nil)
      expect(d[:cf_share]).to eq(value: 67, count: 2, of: 3, release: 50, better: nil)
    end

    it "fills lineage, reviews and worked with" do
      expect(data[:lineage][:verdicts]).to eq(as_is: 2, modified: 0, partial: 0, from_discussion: 0)
      expect(data[:lineage][:of]).to eq(2)
      expect(data[:lineage][:change_levels]).to eq(light: 0, moderate: 0, significant: 0)
      r = data[:reviews]
      expect(r[:crediting]).to eq(value: 33, count: 1, of: 3, release: 25, better: "up")
      expect(r[:coverage]).to eq(final: 1, earlier: 0, none: 0)
      expect(r[:alone]).to eq(value: 50, count: 1, of: 2, release: 50, better: "down")
      expect(r[:per_commit]).to eq(value: 1.0, release: 1.0, better: "up")
      w = data[:worked_with]
      expect(w[:committed_for][:top].map { |p| [ p[:name], p[:count] ] }).to eq([ [ "Dave", 1 ], [ "Bob", 1 ] ])
      expect(w[:committed_for][:rest]).to eq(people: 0, count: 0, share: 0)
      expect(w[:reviewed_by][:top].map { |p| [ p[:name], p[:count] ] }).to eq([ [ "Carol", 1 ] ])
      expect(w[:reviewed][:top]).to eq([])
    end

    it "builds the pulse" do
      expect(data[:pulse][:strips].map { |s| [ s[:key], s[:split] ] }).to eq([ [ "commits", false ], [ "messages", false ], [ "patch_mails", false ], [ "threads_active", false ] ])
      expect(pick(data, "commits")).to eq("2025-10-06" => 1, "2026-01-12" => 1, "2026-06-29" => 1)
      expect(pick(data, "messages")).to eq("2025-12-01" => 1)
      expect(pick(data, "threads_active")).to eq("2025-12-01" => 1)
    end
  end

  context "a committer without commits this cycle" do
    it "has no commit rank" do
      erin = create(:alias, name: "Erin", email: "erin@example.com").person
      commit = create(:commit, committed_at: Time.zone.parse("2026-03-01 12:00"), branches: %w[REL_18_STABLE])
      create(:commit_person, commit: commit, person: erin, role: CommitPerson::COMMITTER, raw_name: "Erin", raw_email: "erin@example.com")
      data = described_class.new(release, erin, overview: overview).to_h
      expect(data[:person][:committer]).to be(true)
      expect(data[:code][:commits]).to eq(value: 0, rank: nil, of: 2)
      expect(data[:code][:lines]).to include(rank: nil, of: 2)
      expect(data[:discussion][:messages]).to eq(value: 0, rank: nil, of: 3)
    end
  end

  context "a mail-only contributor" do
    it "has no author rank" do
      frank = create(:alias, name: "Frank", email: "frank@example.com").person
      create(:message, topic: fx.topics[:t1], sender_alias: frank.default_alias, created_at: Time.zone.parse("2025-10-02 10:00"))
      data = described_class.new(release, frank, overview: overview).to_h
      expect(data[:code][:authored]).to eq(value: 0, rank: nil, of: 3)
      expect(data[:code]).not_to have_key(:reviewed_for_others)
      expect(data[:discussion][:messages]).to eq(value: 1, rank: 4, of: 4)
      expect(data[:discussion][:versions][:value]).to be_nil
    end
  end

  context "a contributor" do
    let(:data) { described_class.new(release, fx.people["bob"], overview: overview).to_h }

    it "shows authored instead of committed" do
      expect(data[:person][:committer]).to be(false)
      expect(data[:code][:commits]).to be_nil
      expect(data[:code][:authored]).to eq(value: 1, rank: 3, of: 3)
      expect(data[:code][:reviewed]).to eq(value: 0)
      expect(data[:discussion][:messages]).to eq(value: 5, rank: 1, of: 3)
      expect(data[:discussion][:threads_started]).to eq(value: 1, landed: 1, landed_share: 100, release: 75, better: nil)
      expect(data[:discussion][:people_talked_to]).to eq(value: 2, committers: 1, others: 1)
      expect(data[:lineage][:verdicts][:as_is]).to eq(1)
      expect(data[:reviews][:crediting]).to eq(value: 100, count: 1, of: 1, release: 25, better: "up")
      expect(data[:reviews][:alone]).to be_nil
      expect(data[:worked_with][:committed_by][:top].map { |p| p[:name] }).to eq([ "Alice" ])
      expect(pick(data, "patch_mails")).to eq("2025-09-01" => 1, "2025-09-29" => 2)
    end
  end
end
