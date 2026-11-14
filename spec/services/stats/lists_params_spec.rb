require "rails_helper"

RSpec.describe Stats::ListsParams do
  let(:today) { Date.new(2026, 11, 14) }
  let!(:hackers) { create(:mailing_list, identifier: "pgsql-hackers") }
  let!(:general) { create(:mailing_list, identifier: "pgsql-general") }
  let!(:committers) { create(:mailing_list, identifier: "pgsql-committers", hidden_by_default: true) }

  def build(params = {}) = described_class.new(params: params, today: today)

  it "defaults" do
    p = build
    expect(p.lists).to eq([ hackers, general ])
    expect(p.mask).to eq(3)
    expect([ p.from, p.to, p.gran ]).to eq([ Date.new(2017, 1, 1), Date.new(2026, 11, 30), "month" ])
    expect(p.default_lists?).to be(true)
  end

  it "parses lists" do
    expect(build(lists: "pgsql-committers,nope").lists).to eq([ committers ])
    expect(build(lists: [ "pgsql-general", "pgsql-hackers" ]).mask).to eq(3)
    expect(build(lists: "nope").lists).to eq([ hackers, general ])
  end

  it "parses and fixes the range" do
    p = build(from: "2020", to: "2019-03")
    expect([ p.from, p.to ]).to eq([ Date.new(2019, 3, 1), Date.new(2020, 12, 31) ])
    expect(build(from: "2020-13").from).to eq(Date.new(2017, 1, 1))
    expect(build(to: "2030").to).to eq(Date.new(2026, 11, 30))
  end

  it "falls back to defaults when clamping inverts the range" do
    [ { from: "2030", to: "2031" }, { from: "1990", to: "1995" }, { to: "1990" }, { from: "2030" } ].each do |q|
      p = build(q)
      expect([ p.from, p.to ]).to eq([ Date.new(2017, 1, 1), Date.new(2026, 11, 30) ])
    end
  end

  it "limits weeks to short ranges" do
    expect(build(gran: "week").gran).to eq("month")
    expect(build(gran: "week", from: "2025-01").gran).to eq("week")
    expect(build(gran: "bogus").gran).to eq("month")
  end

  it "round-trips through to_query" do
    p = build(lists: "pgsql-general", from: "2024-02", to: "2024-05", gran: "quarter")
    expect(p.to_query).to eq(lists: "pgsql-general", from: "2024-02", to: "2024-05", gran: "quarter")
    expect(build(p.to_query).cache_key).to eq(p.cache_key)
  end

  it "normalizes the regulars and newcomers cache keys" do
    p = build
    expect(p.regulars_cache_key(nil, nil)).to eq(p.regulars_cache_key("threads", ""))
    expect(p.regulars_cache_key("bogus", "junk")).to eq(p.regulars_cache_key(nil, nil))
    expect(p.regulars_cache_key("days", "2025-1")).to eq(p.regulars_cache_key("days", "2025-01"))
    expect(p.regulars_cache_key("days", "2025-01")).not_to eq(p.regulars_cache_key("days", "2025-02"))
    expect(build(gran: "year").regulars_cache_key(nil, nil)).to eq(build(gran: "quarter").regulars_cache_key(nil, nil))
    expect(build(gran: "year").newcomers_cache_key).to eq(build(gran: "quarter").newcomers_cache_key)
  end

  it "leaves archived lists out of the default" do
    patches = create(:mailing_list, identifier: "pgsql-patches", archived: true)
    p = build
    expect(p.lists).to eq([ hackers, general ])
    expect(p.all_lists).to include(patches)
    expect(build(lists: "pgsql-patches").lists).to eq([ patches ])
  end

  it "builds tab and preset links" do
    p = build(lists: "pgsql-general")
    expect(p.tab_query).to eq(lists: "pgsql-general")
    q = build(lists: "pgsql-general", from: "2024-01", to: "2024-06")
    expect(q.tab_query).to eq(lists: "pgsql-general", from: "2024-01", to: "2024-06")
    expect(p.preset_query(3)).to include(from: "2023-12", to: "2026-11")
    expect(p.preset_query(nil)).to include(from: "1997-01")
    expect(p.week_allowed?).to be(false)
    expect(q.week_allowed?).to be(true)
    expect(q.preset_query(1)[:lists]).to eq("pgsql-general")
  end

  it "drops explicit_range when the range resets to defaults" do
    expect(build(from: "2024-01", to: "2024-06").explicit_range?).to be(true)
    expect(build(from: "2024-01").explicit_range?).to be(false)
    expect(build(from: "2030-01", to: "2030-06").explicit_range?).to be(false)
  end
end
