require "rails_helper"

RSpec.describe Stats::Lists::Monthly do
  let(:source) do
    "SELECT * FROM (VALUES (DATE '2024-01-01', 1::bigint, 2, 1, 1), (DATE '2024-01-01', 2::bigint, 1, 3, 1), " \
      "(DATE '2024-02-01', 2::bigint, 4, 1, 2)) AS s(month, person_id, messages, threads, days)"
  end

  def rows(sql) = ActiveRecord::Base.connection.select_all(sql).to_a

  it "ranks raw counts per month" do
    got = rows(described_class.new(source_sql: source).rows_sql)
    jan = got.select { |r| r["month"].to_s == "2024-01-01" }.index_by { |r| r["person_id"] }
    expect(jan[1]["score_messages"]).to eq(2)
    expect(jan[1]["rank_messages"]).to eq(1)
    expect(jan[2]["rank_threads"]).to eq(1)
    expect(jan[2]["rank_days"]).to eq(2)
    expect(got.count { |r| r["month"].to_s == "2024-02-01" }).to eq(1)
  end

  it "keeps only top ranks and adds totals" do
    got = rows(described_class.new(source_sql: source, keep: 1).rows_sql(totals: true))
    jan = got.select { |r| r["month"].to_s == "2024-01-01" }
    expect(jan.map { |r| r["person_id"] }).to contain_exactly(1, 2)
    expect(jan.first["total_messages"]).to eq(3)
  end

  it "sums totals" do
    t = rows(described_class.new(source_sql: source).totals_sql).index_by { |r| r["month"].to_s }
    expect(t["2024-01-01"]["total_threads"]).to eq(4)
    expect(t["2024-02-01"]["total_messages"]).to eq(4)
  end
end
