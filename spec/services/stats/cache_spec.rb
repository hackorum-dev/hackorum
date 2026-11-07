require "rails_helper"

RSpec.describe Stats::Cache do
  let(:open_release) { instance_double(Stats::Period::Release, kind: :release, key: "19", closed?: false) }
  let(:closed_release) { instance_double(Stats::Period::Release, kind: :release, key: "18", closed?: true) }
  let(:version) { 4 }

  it "expires the open release after an hour" do
    expect(Rails.cache).to receive(:fetch)
      .with([ "stats", version, "release", "19", "overview", [] ], expires_in: 1.hour, race_condition_ttl: 1.minute)
      .and_return(:x)
    expect(described_class.fetch(open_release, "overview") { :y }).to eq(:x)
  end

  it "keeps a closed release forever and keys on extras" do
    expect(Rails.cache).to receive(:fetch)
      .with([ "stats", version, "release", "18", "pulse", [ [ :gran, "week" ] ] ], expires_in: nil)
      .and_return(:x)
    described_class.fetch(closed_release, "pulse", gran: "week") { :y }
  end

  it "skips the store in development" do
    allow(Rails.env).to receive(:development?).and_return(true)
    expect(Rails.cache).not_to receive(:fetch)
    expect(described_class.fetch(closed_release, "overview") { :y }).to eq(:y)
  end

  it "round-trips the overview through a real store" do
    allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
    travel_to(Time.zone.parse("2026-11-06 12:00"))
    build_stats_release_fixture
    release = Stats::Period::Release.new(19)
    calls = 0
    load = -> { described_class.fetch(release, :overview) { calls += 1; Stats::Period::Overview.new(release).to_h } }

    first = load.call
    second = load.call
    expect(second).to eq(first)
    expect(calls).to eq(1)
  end
end
