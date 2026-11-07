require "rails_helper"

RSpec.describe Stats::Period::Release do
  let(:now) { Time.zone.parse("2026-11-06 12:00") }
  let!(:fx) { build_stats_release_fixture }

  before { travel_to(now) }

  describe "an open release" do
    subject(:release) { described_class.new(19) }

    it "names its branches and tags" do
      expect(release.branch).to eq("REL_19_STABLE")
      expect(release.previous_branch).to eq("REL_18_STABLE")
      expect(release.label).to eq("PG19")
      expect(release).not_to be_closed
    end

    it "takes phase boundaries from the tags" do
      expect(release.start).to eq(Time.zone.parse("2025-05-05 20:00"))
      expect(release.previous_ga).to eq(Time.zone.parse("2025-09-22 20:00"))
      expect(release.branch_point).to eq(Time.zone.parse("2026-06-01 20:00"))
      expect(release.end_at).to eq(now)
    end
  end

  describe "a closed release" do
    it "ends at the GA tag" do
      create(:release_tag, name: "REL_17_BETA1", released_at: Time.zone.parse("2024-05-01"))
      release = described_class.new(18)
      expect(release).to be_closed
      expect(release.end_at).to eq(Time.zone.parse("2025-09-22 20:00"))
      expect(release.start).to eq(Time.zone.parse("2024-05-01"))
    end
  end

  describe ".available" do
    it "lists majors with a branch, newest first, plus the one in development" do
      create(:release_tag, name: "REL_17_BETA1", released_at: Time.zone.parse("2024-05-01"))
      expect(described_class.available.map(&:major)).to eq([ 20, 19, 18 ])
      expect(described_class.available.first).to be_in_development
      expect(described_class.find(19)).to be_a(described_class)
      expect(described_class.find(7)).to be_nil
      expect(described_class.find(21)).to be_nil
    end

    it "skips a major whose cycle has no start tag" do
      expect(described_class.available.map(&:major)).to eq([ 20, 19 ])
      expect(described_class.find(18)).to be_nil
    end
  end

  it "has company data from PG19 on" do
    expect(described_class.new(18)).not_to be_companies
    expect(described_class.new(19)).to be_companies
  end

  describe "the release in development" do
    it "uses master as its branch and has no branch point" do
      release = described_class.new(20)
      expect(release.branch).to eq("master")
      expect(release.previous_branch).to eq("REL_19_STABLE")
      expect(release.start).to eq(Time.zone.parse("2026-06-01 20:00"))
      expect(release.previous_ga).to be_nil
      expect(release.branch_point).to be_nil
      expect(release.end_at).to eq(now)
    end
  end

  describe "the period interface" do
    let(:release) { described_class.new(19) }

    it "describes itself for the header and the tabs" do
      expect(release.kind).to eq(:release)
      expect(release.key).to eq("19")
      expect(release.slug).to eq("pg19")
      expect(release.noun).to eq("cycle")
      expect(release.pill_noun).to eq("release")
      expect(release.title).to eq("PG19")
      expect(release.long_label).to eq("PG19")
      expect(release.range_text).to eq("Cycle: 2025-05-05 (18 branched) to PG19 GA (not yet tagged)")
      expect(release.scope_description).to eq("commits in the 19 branch that are not in 18")
      expect(release.backported_description).to eq("to an earlier branch too")
      expect(release).to be_open
      expect(release).not_to be_in_progress
      expect(described_class.new(20)).to be_in_progress
      expect(described_class.new(20).in_progress_label).to eq("in development")
    end

    it "closes the range text at the GA tag" do
      create(:release_tag, name: "REL_19_0", released_at: Time.zone.parse("2026-09-01 20:00"))
      expect(described_class.new(19).range_text).to eq("Cycle: 2025-05-05 (18 branched) to 2026-09-01 (19.0)")
    end

    it "has three phase windows and its own release events" do
      expect(release.windows).to eq([
        [ release.start, release.previous_ga, :early ],
        [ release.previous_ga, release.branch_point, :middle ],
        [ release.branch_point, now, :late ]
      ])
      expect(release.phase_at(Time.zone.parse("2025-01-01"))).to eq(:early)
      expect(release.phase_at(Time.zone.parse("2026-03-01"))).to eq(:middle)
      expect(release.phase_at(Time.zone.parse("2026-07-01"))).to eq(:late)
      expect(release.events).to eq([
        { at: release.previous_ga, label: "18.0 GA" },
        { at: release.branch_point, label: "19 branched (beta1)" }
      ])
    end

    it "finds by key and names its neighbours" do
      expect(described_class.find("19")).to be_a(described_class)
      expect(described_class.find("abc")).to be_nil
      expect(release.neighbours.map(&:major)).to eq([ 20 ])
      create(:release_tag, name: "REL_17_BETA1", released_at: Time.zone.parse("2024-05-01"))
      expect(described_class.new(19).neighbours.map(&:major)).to eq([ 20, 18 ])
      expect(described_class.new(19).neighbours(described_class.available).map(&:major)).to eq([ 20, 18 ])
    end

    it "knows the threads that shipped in the previous major before its GA" do
      expect(release.previous_landed_topics.pluck(:topic_id)).to eq([])
      create(:commit_topic, commit: fx.commits[:c5], topic: fx.topics[:t3])
      expect(described_class.new(19).previous_landed_topics.pluck(:topic_id)).to eq([ fx.topics[:t3].id ])
      expect(described_class.new(20).previous_landed_topics).to be_nil
    end
  end
end
