require "rails_helper"

RSpec.describe Stats::Release::Phases do
  let(:now) { Time.zone.parse("2026-11-06 12:00") }

  before do
    build_stats_release_fixture
    travel_to(now)
    create(:release_tag, name: "REL_19_BETA2", released_at: Time.zone.parse("2026-07-13 20:00"))
    create(:release_tag, name: "REL_19_RC1", released_at: Time.zone.parse("2026-10-12 20:00"))
    create(:commitfest, name: "PG19-1", start_date: Date.new(2025, 7, 1), end_date: Date.new(2025, 7, 31))
    create(:commitfest, name: "PG19-Drafts", start_date: Date.new(2025, 6, 22), end_date: Date.new(2026, 2, 28))
    create(:commitfest, name: "PG17-1", start_date: Date.new(2023, 7, 1), end_date: Date.new(2023, 7, 31))
  end

  let(:release) { Stats::Release.new(19) }

  it "splits the cycle into three windows" do
    phases = described_class.new(release, gran: "month")
    expect(phases.windows).to eq([
      [ release.start, release.previous_ga, :early ],
      [ release.previous_ga, release.branch_point, :middle ],
      [ release.branch_point, now, :late ]
    ])
    expect(phases.phase_at(Time.zone.parse("2025-06-01"))).to eq(:early)
    expect(phases.phase_at(Time.zone.parse("2026-03-01"))).to eq(:middle)
    expect(phases.phase_at(Time.zone.parse("2026-07-01"))).to eq(:late)
  end

  it "has one early window for the release in development" do
    phases = described_class.new(Stats::Release.new(20), gran: "month")
    expect(phases.windows).to eq([ [ release.branch_point, now, :early ] ])
  end

  it "buckets by month with labels and phases" do
    buckets = described_class.new(release, gran: "month").buckets
    expect(buckets.size).to eq(19)
    expect(buckets.first).to eq(start: Time.zone.parse("2025-05-01"), label: "May 2025", phase: :early)
    expect(buckets.find { |b| b[:label] == "Oct 2025" }[:phase]).to eq(:middle)
    expect(buckets.last).to eq(start: Time.zone.parse("2026-11-01"), label: "Nov 2026", phase: :late)
  end

  it "buckets by week starting on Mondays" do
    buckets = described_class.new(release, gran: "week").buckets
    expect(buckets.first[:start]).to eq(Time.zone.parse("2025-05-05"))
    expect(buckets.first[:label]).to eq("2025-05-05")
    expect(buckets.last[:start]).to eq(Time.zone.parse("2026-11-02"))
    expect(buckets.size).to eq(79)
  end

  it "lists short commitfests inside the cycle as bands" do
    bands = described_class.new(release, gran: "week").bands
    expect(bands).to eq([ { from: Date.new(2025, 7, 1), to: Date.new(2025, 7, 31), label: "PG19-1" } ])
  end

  it "lists the release events inside the cycle" do
    events = described_class.new(release, gran: "week").events
    expect(events).to eq([
      { at: release.previous_ga, label: "18.0 GA" },
      { at: release.branch_point, label: "19 branched (beta1)" },
      { at: Time.zone.parse("2026-07-13 20:00"), label: "beta2" },
      { at: Time.zone.parse("2026-10-12 20:00"), label: "rc1" }
    ])
  end

  it "ends a closed release at its GA" do
    ga = Time.zone.parse("2026-09-01 20:00")
    create(:release_tag, name: "REL_19_0", released_at: ga)
    phases = described_class.new(Stats::Release.new(19), gran: "month")
    expect(phases.windows.last).to eq([ release.branch_point, ga, :late ])
    expect(phases.buckets.last[:label]).to eq("Sep 2026")
    expect(phases.events.last).to eq(at: ga, label: "19.0 GA")
  end

  it "keeps the late phase when the previous GA tag is missing" do
    ReleaseTag.where(name: "REL_18_0").delete_all
    phases = described_class.new(Stats::Release.new(19), gran: "month")
    expect(phases.windows).to eq([
      [ release.start, release.branch_point, :early ],
      [ release.branch_point, now, :late ]
    ])
  end
end
