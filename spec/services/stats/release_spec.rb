require "rails_helper"

RSpec.describe Stats::Release do
  let(:now) { Time.zone.parse("2026-11-06 12:00") }

  before do
    build_stats_release_fixture
    travel_to(now)
  end

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
end
