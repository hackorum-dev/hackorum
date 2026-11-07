require "rails_helper"

RSpec.describe Stats::Period::Overview do
  let(:now) { Time.zone.parse("2026-11-06 12:00") }
  let!(:fx) { build_stats_release_fixture }
  let(:overview) { described_class.new(Stats::Period::Release.new(19)).to_h }

  before { travel_to(now) }

  describe "code band" do
    subject(:code) { overview[:code] }

    it "counts commits and their shape" do
      expect(code.slice(:commits, :backported, :reverts, :authors, :reviewers, :files, :lines_added, :lines_removed))
        .to eq(commits: 4, backported: 2, reverts: 1, authors: 2, reviewers: 1, files: 4, lines_added: 132, lines_removed: 18)
    end

    it "ranks committers" do
      expect(code[:committers]).to eq(count: 2, strip: [ [ "Alice", 3 ], [ "Dave", 1 ] ], top5_share: 100)
      expect(code[:committer_steps]).to eq("1+" => 2, "10+" => 0, "50+" => 0, "100+" => 0)
    end

    it "buckets by month over the whole cycle" do
      months = code[:commits_by_month]
      expect(months.first.first).to eq("May 2025")
      expect(months.last.first).to eq("Nov 2026")
      expect(months.to_h["Oct 2025"]).to eq(1)
      expect(months.to_h["Jul 2026"]).to eq(1)
      expect(code[:peak]).to eq([ "Oct 2025", 1 ])
      expect(code[:lines_by_month].to_h["Oct 2025"]).to eq([ 100, 10 ])
      expect(code[:lines_by_month].to_h["Nov 2025"]).to eq([ 0, 0 ])
      expect(code[:lines_by_month].to_h["Jul 2026"]).to eq([ 7, 3 ])
    end
  end

  describe "discussion band" do
    subject(:discussion) { overview[:discussion] }

    it "counts the release threads" do
      expect(discussion.slice(:threads, :messages, :people, :patch_mails, :with_thread))
        .to eq(threads: 3, messages: 7, people: 3, patch_mails: 3, with_thread: 3)
      expect(discussion[:patch_mails_per_thread]).to eq(1.0)
    end

    it "measures thread age at commit" do
      expect(discussion[:age_median_days]).to eq(40)
      expect(discussion[:age_buckets]).to eq([ [ "under 1 week", 0 ], [ "1 to 4 weeks", 1 ], [ "1 to 3 months", 2 ], [ "3 to 6 months", 0 ],
                                                [ "6 to 12 months", 0 ], [ "1 to 2 years", 0 ], [ "over 2 years", 0 ] ])
      expect(discussion[:within_2w]).to eq(1)
      expect(discussion[:over_year]).to eq(0)
    end
  end

  describe "podiums" do
    it "ranks committers by commits and non-committers by credits" do
      committers = overview[:podiums][:committers]
      expect(committers.map { |p| [ p[:name], p[:commits] ] }).to eq([ [ "Alice", 3 ], [ "Dave", 1 ] ])
      expect(committers.first[:email]).to eq("alice@example.com")

      contributors = overview[:podiums][:contributors]
      expect(contributors.map { |p| [ p[:name], p[:authored], p[:reviewed] ] }).to eq([ [ "Bob", 1, 0 ], [ "Carol", 0, 1 ] ])
      expect(contributors.first[:email]).to eq("bob@example.com")
    end

    it "counts credits earned before the person got the commit bit" do
      fx.commits[:c3].update!(committed_at: Time.zone.parse("2026-08-01 12:00"))
      fx.commits[:c3b].update!(committed_at: Time.zone.parse("2026-08-01 12:30"))
      # c6 is Dave's too, it must not give him the bit early
      fx.commits[:c6].update!(committed_at: Time.zone.parse("2026-08-01 12:00"))
      contributors = described_class.new(Stats::Period::Release.new(19)).to_h[:podiums][:contributors]
      expect(contributors.map { |p| [ p[:name], p[:authored], p[:reviewed] ] }).to contain_exactly([ "Bob", 1, 0 ], [ "Carol", 0, 1 ], [ "Dave", 1, 0 ])
    end
  end

  describe "lineage band" do
    subject(:lineage) { overview[:lineage] }

    it "reports coverage and verdicts" do
      expect(lineage[:covered]).to eq(3)
      expect(lineage[:verdicts]).to eq(as_is: 2, modified: 1, partial: 0, from_discussion: 0)
      expect(lineage[:change_levels]).to eq(light: 1, moderate: 0, significant: 0)
    end

    it "counts versions per patch along the lineage chain" do
      expect(lineage[:versions]).to include(mean: 3.0, median: 3, max: 3)
      expect(lineage[:versions][:buckets].to_h["3"]).to eq(1)
    end

    it "relates commits to commitfest entries" do
      expect(lineage.slice(:cf_commits, :cf_entries, :batches_per_entry, :one_batch_entries))
        .to eq(cf_commits: 2, cf_entries: 1, batches_per_entry: 2.0, one_batch_entries: 0)
      expect(lineage[:commits_per_entry]).to eq(mean: 2.0, median: 2)
    end
  end

  describe "reviews band" do
    subject(:reviews) { overview[:reviews] }

    it "separates credited from seen" do
      expect(reviews[:crediting]).to eq(1)
      expect(reviews[:per_commit]).to eq(mean: 1.0, median: 1)
      expect(reviews[:coverage]).to eq(final: 1, earlier: 0, none: 0)
      expect(reviews[:uncredited_reviewed]).to eq(count: 1, of: 3, credits: 1)
    end

    it "knows who committed for whom" do
      expect(reviews[:by_others]).to eq(count: 2, committers: 1, non_committers: 1)
      expect(reviews[:alone]).to eq(count: 1, of: 2)
      expect(reviews[:size][:categories]).to eq([ "under 10 lines", "10 to 50", "50 to 200", "200 to 1,000", "over 1,000" ])
      expect(reviews[:size][:alone]).to eq([ 0, 1, 0, 0, 0 ])
      expect(reviews[:size][:with_other]).to eq([ 0, 0, 1, 0, 0 ])
    end
  end

  describe "a release with one commit and no thread" do
    let(:overview) do
      create(:release_tag, name: "REL_17_BETA1", released_at: Time.zone.parse("2024-05-01"))
      described_class.new(Stats::Period::Release.new(18)).to_h
    end

    it "keeps the bands defined" do
      expect(overview[:code][:commits]).to eq(1)
      expect(overview[:code][:peak]).to eq([ "Apr 2025", 1 ])
      expect(overview[:code][:committers][:top5_share]).to eq(100)
      expect(overview[:discussion][:age_median_days]).to be_nil
      expect(overview[:discussion][:with_thread]).to eq(0)
    end
  end
end
