require "rails_helper"

RSpec.describe Stats::Lists::Newcomers do
  let!(:fx) { build_stats_lists_fixture }
  let(:today) { Date.new(2024, 4, 10) }

  before { Stats::Lists::Builder.new.run! }

  def build(q = {})
    params = Stats::ListsParams.new(params: { from: "2023-10", to: "2024-03" }.merge(q), today: today)
    described_class.new(params, today: today).to_h
  end

  it "counts the selection's newcomers" do
    d = build
    # default mask 3: ann, bob, carl, dan (cora's first message is on the hidden list)
    expect(d[:tiles][:newcomers]).to eq(4)
    expect(d[:tiles][:came_back]).to eq(75.0)
    expect(d[:tiles][:became_active]).to eq(0.0)
    expect(d[:tiles][:top50]).to eq(100.0)
    expect(d[:cohorts]).to eq([ "2023 Q4", "2024 Q1" ])
  end

  it "builds retention with immature points cut" do
    lines = build[:retention][:lines].index_by { |l| l[:label] }
    # 2023 Q4 = dan (offsets [0]); k=1..3 end by 2024-03-31 <= today, k=4 is 2024-04-30 > today
    expect(lines["2023 Q4"][:values].first(4)).to eq([ 0.0, 0.0, 0.0, nil ])
    # 2024 Q1 ends 2024-03-31; k=1 is 2024-04-30 > today, so no point at all and no line
    expect(lines).not_to have_key("2024 Q1")
    expect(lines["2023 Q4"][:gray]).to be(false)
  end

  it "labels paths" do
    d = build
    expect(d[:paths][:series].map { |s| s[:label] }).to eq([ "sent a patch", "started a thread", "only replied" ])
    expect(d[:path_table].map { |r| r[:label] }).to eq([ "sent a patch", "started a thread", "only replied" ])
  end

  it "lists fast risers" do
    names = build[:risers].map { |r| r[:name] }
    expect(names).to include("Ann", "Bob", "Carl", "Dan")
    expect(build[:risers].first.keys).to include(:weeks_to_top50, :spark, :path, :lists)
  end
end
