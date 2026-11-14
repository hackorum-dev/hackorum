require "rails_helper"

RSpec.describe Stats::Lists::Volume do
  let!(:fx) { build_stats_lists_fixture }
  let(:today) { Date.new(2024, 4, 10) }
  let(:params) { Stats::ListsParams.new(params: { from: "2024-01", to: "2024-03" }, today: today) }
  let(:data) { described_class.new(params, today: today).to_h }

  before { Stats::Lists::Builder.new.run! }

  def values(series) = series.map { |s| [ s[:label], s[:values] ] }.to_h

  it "returns the periods" do
    expect(data[:categories]).to eq(%w[2024-01 2024-02 2024-03])
    expect(data[:open]).to eq([ false, false, false ])
  end

  it "splits messages and people by group" do
    expect(values(data[:messages])).to eq("committers" => [ 0, 1, 0 ], "contributors" => [ 1, 0, 0 ], "others" => [ 3, 1, 1 ])
    expect(values(data[:people])).to eq("committers" => [ 0, 1, 0 ], "contributors" => [ 1, 0, 0 ], "others" => [ 3, 1, 1 ])
    expect(data[:messages].last[:gray]).to be(true)
  end

  it "counts threads and newcomers" do
    expect(values(data[:threads])).to eq("new" => [ 2, 1, 0 ], "active" => [ 2, 2, 1 ])
    expect(values(data[:newcomers])).to eq("new to the community" => [ 3, 0, 0 ], "new to these lists" => [ 4, 0, 0 ])
  end

  it "shares messages between the lists" do
    expect(values(data[:by_list])).to eq("pgsql-hackers" => [ 60.0, 100.0, 100.0 ], "pgsql-general" => [ 40.0, 0.0, 0.0 ])
  end

  it "sums the range for the tiles" do
    expect(data[:tiles].transform_values { |t| t[:value] })
      .to eq(messages: 7, threads_new: 3, people: 4, newcomers_community: 3, newcomers_selection: 4)
    expect(data[:tiles].transform_values { |t| t[:change] })
      .to eq(messages: 600, threads_new: 200, people: 300, newcomers_community: 200, newcomers_selection: 300)
  end

  it "has no change without a previous period" do
    p = Stats::ListsParams.new(params: { from: "2023-11", to: "2023-11" }, today: today)
    d = described_class.new(p, today: today).to_h
    expect(d[:tiles][:messages][:change]).to be_nil
  end

  it "fills empty periods with zeros" do
    p = Stats::ListsParams.new(params: { from: "2023-10", to: "2024-01" }, today: today)
    d = described_class.new(p, today: today).to_h
    expect(values(d[:threads])["new"]).to eq([ 0, 0, 1, 2 ])
  end
end
