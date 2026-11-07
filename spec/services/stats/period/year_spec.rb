require "rails_helper"

RSpec.describe Stats::Period::Year do
  let(:now) { Time.zone.parse("2026-11-06 12:00") }
  let!(:fx) { build_stats_release_fixture }

  before { travel_to(now) }

  it "lists the years from the floor to today, newest first" do
    years = described_class.available
    expect(years.map(&:key)).to eq(%w[2026 2025 2024 2023 2022 2021 2020 2019 2018 2017])
    expect(years.first).to be_open
    expect(years.first).to be_in_progress
    expect(years.second).to be_closed
    expect(described_class.find("2025")).to be_a(described_class)
    expect(described_class.find("1990")).to be_nil
    expect(described_class.find("abc")).to be_nil
  end

  it "runs from January to the next January, or to today" do
    year = described_class.new(2025)
    expect(year.kind).to eq(:year)
    expect(year.label).to eq("2025")
    expect(year.slug).to eq("2025")
    expect(year.title).to eq("2025")
    expect(year.long_label).to eq("2025")
    expect(year.noun).to eq("year")
    expect(year.pill_noun).to eq("year")
    expect(year.in_progress_label).to eq("in progress")
    expect(year.start).to eq(Time.zone.parse("2025-01-01"))
    expect(year.end_at).to eq(Time.zone.parse("2026-01-01"))
    expect(year.range_text).to eq("Year: 2025-01-01 to 2025-12-31")
    expect(year.scope_description).to eq("committed between 2025-01-01 and 2025-12-31, one per change, backports collapsed")
    expect(year.backported_description).to eq("cherry-picked to another branch too")
    open = described_class.new(2026)
    expect(open.end_at).to eq(now)
    expect(open.range_text).to eq("Year: 2026-01-01 to today")
    expect(open.scope_description).to eq("committed between 2026-01-01 and today, one per change, backports collapsed")
  end

  it "is one middle window with every release event labelled by major" do
    year = described_class.new(2025)
    expect(year.windows).to eq([ [ year.start, year.end_at, :middle ] ])
    expect(year.phase_at(Time.zone.parse("2025-06-01"))).to eq(:middle)
    expect(year.branch_point).to be_nil
    expect(year.previous_ga).to be_nil
    expect(year.previous_landed_topics).to be_nil
    expect(year.events).to eq([
      { at: Time.zone.parse("2025-05-05 20:00"), label: "18 branched (beta1)" },
      { at: Time.zone.parse("2025-09-22 20:00"), label: "18.0 GA" }
    ])
    create(:release_tag, name: "REL_19_RC1", released_at: Time.zone.parse("2026-10-12 20:00"))
    expect(described_class.new(2026).events.map { |e| e[:label] }).to eq([ "19 branched (beta1)", "19 rc1" ])
  end

  it "has company data from the PG19 cycle on" do
    expect(described_class.new(2025)).not_to be_companies
    expect(described_class.new(2026)).to be_companies
  end

  it "scopes commits by the representative's time, master copy first" do
    scopes = described_class.new(2026).scopes
    expect(scopes.commits.pluck(:sha)).to contain_exactly(fx.commits[:c2].sha, fx.commits[:c3].sha, fx.commits[:c4].sha, fx.commits[:c6].sha)
    expect(scopes.backported).to eq(2)
    expect(scopes.threads.pluck(:id)).to contain_exactly(fx.topics[:t2].id, fx.topics[:t4].id)
    expect(described_class.new(2025).scopes.commits.pluck(:sha)).to contain_exactly(fx.commits[:c1].sha, fx.commits[:c5].sha)
    expect(described_class.new(2025).scopes.backported).to eq(0)
    expect(described_class.new(2024).scopes.commits.pluck(:sha)).to eq([ fx.commits[:c7].sha ])
  end

  it "counts every non-notice message in the window" do
    year = described_class.new(2026)
    expect(year.scopes.messages_between(year.start, year.end_at).pluck(:id)).to eq([ fx.messages[:t3_mid].id ])
    expect(described_class.new(2025).scopes.messages_between(Time.zone.parse("2025-01-01"), Time.zone.parse("2026-01-01")).count).to eq(8)
  end

  it "names its neighbours" do
    expect(described_class.new(2025).neighbours.map(&:key)).to eq(%w[2026 2024])
    expect(described_class.new(2026).neighbours.map(&:key)).to eq(%w[2025])
  end
end
