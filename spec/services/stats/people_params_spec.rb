require "rails_helper"

RSpec.describe Stats::PeopleParams do
  let(:rows) { [ { id: 1, committer: true, authored: 5, reviewed: 1, messages: 9 }, { id: 2, committer: false, authored: 2, reviewed: 7, messages: 1 }, { id: 3, committer: false, authored: 0, reviewed: 1, messages: 4 } ] }

  it "defaults and whitelists" do
    p = described_class.new(params: {})
    expect([ p.rank, p.committers, p.sort, p.dir, p.all? ]).to eq([ "credits", "included", "credits", "desc", false ])
    p = described_class.new(params: { rank: "messages", committers: "excluded", sort: "nope", dir: "asc", all: "1" })
    expect([ p.rank, p.committers, p.sort, p.dir, p.all? ]).to eq([ "messages", "excluded", "messages", "asc", true ])
  end

  it "orders and filters rows" do
    expect(described_class.new(params: {}).order_rows(rows).map { |r| r[:id] }).to eq([ 2, 1, 3 ])
    expect(described_class.new(params: { sort: "messages", dir: "asc" }).order_rows(rows).map { |r| r[:id] }).to eq([ 2, 3, 1 ])
    expect(described_class.new(params: { committers: "excluded" }).order_rows(rows).map { |r| r[:id] }).to eq([ 2, 3 ])
  end

  it "ranks the top rows by rank, not by the table sort" do
    p = described_class.new(params: { rank: "messages", sort: "authored", dir: "asc" })
    expect(p.top_rows(rows).map { |r| r[:id] }).to eq([ 1, 3, 2 ])
  end
end
