require "rails_helper"

RSpec.describe Stats::Period do
  let(:now) { Time.zone.parse("2026-11-06 12:00") }

  before do
    build_stats_release_fixture
    travel_to(now)
  end

  it "looks a period up by kind and key" do
    expect(described_class.kind_class("release")).to eq(Stats::Period::Release)
    expect(described_class.kind_class("year")).to eq(Stats::Period::Year)
    expect(described_class.kind_class("cycle")).to eq(Stats::Period::Cycle)
    expect(described_class.kind_class("nope")).to be_nil
    expect(described_class.lookup("release", "19")).to be_a(Stats::Period::Release)
    expect(described_class.lookup("year", "2025")).to be_a(Stats::Period::Year)
    expect(described_class.lookup("cycle", "2025")).to be_a(Stats::Period::Cycle)
    expect(described_class.lookup("release", "7")).to be_nil
    expect(described_class.lookup("year", "1990")).to be_nil
    expect(described_class.lookup("nope", "19")).to be_nil
  end

  it "lists every period of every kind" do
    all = described_class.all.map { |p| [ p.kind, p.key ] }
    expect(all.first(2)).to eq([ [ :release, "20" ], [ :release, "19" ] ])
    expect(all.select { |k, _| k == :year }.size).to eq(10)
    expect(all.last(2)).to eq([ [ :cycle, "2026" ], [ :cycle, "2025" ] ])
  end

  it "starts curated company data at the PG19 cycle" do
    expect(described_class.companies_from).to eq(Time.zone.parse("2025-05-05 20:00"))
  end
end
