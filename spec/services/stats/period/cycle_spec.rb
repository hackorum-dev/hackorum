require "rails_helper"

RSpec.describe Stats::Period::Cycle do
  let(:now) { Time.zone.parse("2026-11-06 12:00") }
  let!(:fx) { build_stats_release_fixture }

  before { travel_to(now) }

  it "runs from one branch point to the next, newest first, the newest open" do
    cycles = described_class.available
    expect(cycles.map(&:key)).to eq(%w[2026 2025])
    expect(cycles.map(&:label)).to eq([ "2026/27", "2025/26" ])
    expect(cycles.map(&:major)).to eq([ 19, 18 ])
    expect(cycles.first).to be_open
    expect(cycles.first).to be_in_progress
    expect(cycles.first.start).to eq(Time.zone.parse("2026-06-01 20:00"))
    expect(cycles.first.end_at).to eq(now)
    expect(cycles.second).to be_closed
    expect(cycles.second.start).to eq(Time.zone.parse("2025-05-05 20:00"))
    expect(cycles.second.end_at).to eq(Time.zone.parse("2026-06-01 20:00"))
    expect(described_class.find("2025")).to be_a(described_class)
    expect(described_class.find("2024")).to be_nil
    expect(described_class.find("2026").neighbours.map(&:key)).to eq(%w[2025])
  end

  it "describes itself" do
    cycle = described_class.find("2025")
    expect(cycle.kind).to eq(:cycle)
    expect(cycle.slug).to eq("2025-26")
    expect(cycle.title).to eq("2025/26 cycle")
    expect(cycle.long_label).to eq("the 2025/26 cycle")
    expect(cycle.noun).to eq("cycle")
    expect(cycle.pill_noun).to eq("cycle")
    expect(cycle.range_text).to eq("Master: 2025-05-05 (18 branched) to 2026-06-01 (19 branched)")
    expect(cycle.scope_description).to eq("committed between 2025-05-05 and 2026-06-01, one per change, backports collapsed")
    expect(described_class.find("2026").range_text).to eq("Master: 2026-06-01 (19 branched) to today (20 not yet branched)")
  end

  it "is one middle window and shows both branch points as events" do
    cycle = described_class.find("2025")
    expect(cycle.windows).to eq([ [ cycle.start, cycle.end_at, :middle ] ])
    expect(cycle.events.map { |e| e[:label] }).to eq([ "18 branched (beta1)", "18.0 GA", "19 branched (beta1)" ])
    expect(cycle).to be_companies
  end

  it "scopes commits to the master run" do
    expect(described_class.find("2025").scopes.commits.pluck(:sha)).to contain_exactly(fx.commits[:c1].sha, fx.commits[:c2].sha, fx.commits[:c3].sha, fx.commits[:c6].sha)
    expect(described_class.find("2025").scopes.backported).to eq(1)
    expect(described_class.find("2026").scopes.commits.pluck(:sha)).to eq([ fx.commits[:c4].sha ])
    expect(described_class.find("2026").scopes.backported).to eq(1)
    expect(described_class.find("2025").scopes.threads.pluck(:id)).to contain_exactly(fx.topics[:t1].id, fx.topics[:t2].id)
    expect(described_class.find("2026").scopes.threads.pluck(:id)).to eq([ fx.topics[:t4].id ])
    c = described_class.find("2025")
    expect(c.scopes.messages_between(c.start, c.end_at).count).to eq(9)
    c = described_class.find("2026")
    expect(c.scopes.messages_between(c.start, c.end_at).count).to eq(0)
  end

  it "is empty without branch points" do
    ReleaseTag.delete_all
    expect(described_class.available).to eq([])
  end
end
