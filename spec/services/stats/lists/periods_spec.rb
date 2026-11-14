require "rails_helper"

RSpec.describe Stats::Lists::Periods do
  it "lists starts per granularity" do
    from, to = Date.new(2024, 1, 10), Date.new(2024, 3, 5)
    expect(described_class.starts("week", from, to).first(2)).to eq([ Date.new(2024, 1, 8), Date.new(2024, 1, 15) ])
    expect(described_class.starts("month", from, to)).to eq([ Date.new(2024, 1, 1), Date.new(2024, 2, 1), Date.new(2024, 3, 1) ])
    expect(described_class.starts("quarter", from, to)).to eq([ Date.new(2024, 1, 1) ])
    expect(described_class.starts("year", from, to)).to eq([ Date.new(2024, 1, 1) ])
  end

  it "labels and marks the open period" do
    expect(described_class.label("week", Date.new(2024, 1, 8))).to eq("2024-01-08")
    expect(described_class.label("month", Date.new(2024, 2, 1))).to eq("2024-02")
    expect(described_class.label("quarter", Date.new(2024, 4, 1))).to eq("2024 Q2")
    expect(described_class.label("year", Date.new(2024, 1, 1))).to eq("2024")
    expect(described_class.open?("month", Date.new(2024, 2, 1), Date.new(2024, 2, 29))).to be(true)
    expect(described_class.open?("month", Date.new(2024, 1, 1), Date.new(2024, 2, 1))).to be(false)
  end
end
