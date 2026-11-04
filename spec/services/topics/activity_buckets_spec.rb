require "rails_helper"

RSpec.describe Topics::ActivityBuckets do
  def t(str) = Time.zone.parse(str)

  it "buckets by month including empty months" do
    times = [ t("2026-01-03"), t("2026-01-20"), t("2026-03-02") ]
    commits = [ { committed_at: t("2026-03-05"), subject: "Fix" }, { committed_at: t("2025-12-01"), subject: "Old" } ]

    buckets = described_class.new(message_times: times, commit_groups: commits).buckets

    expect(buckets.map(&:label)).to eq([ "Jan 2026", "Feb 2026", "Mar 2026" ])
    expect(buckets.map(&:messages)).to eq([ 2, 0, 1 ])
    expect(buckets.map(&:commits)).to eq([ 0, 0, 1 ])
    expect([ buckets[1].from, buckets[1].to ]).to eq([ Date.new(2026, 2, 1), Date.new(2026, 2, 28) ])
  end

  it "extends the range to a commit after the last message and ignores earlier ones" do
    times = [ t("2026-01-03"), t("2026-01-20") ]
    commits = [ { committed_at: t("2026-03-15"), subject: "Late" }, { committed_at: t("2025-11-01"), subject: "Early" } ]

    buckets = described_class.new(message_times: times, commit_groups: commits).buckets

    expect(buckets.map(&:label)).to eq([ "Jan 2026", "Feb 2026", "Mar 2026" ])
    expect(buckets.map(&:messages)).to eq([ 2, 0, 0 ])
    expect(buckets.map(&:commits)).to eq([ 0, 0, 1 ])
  end

  it "switches to quarters past 24 months and counts reverts" do
    times = [ t("2022-05-31"), t("2024-04-10"), t("2026-06-30") ]
    commits = [ { committed_at: t("2024-08-24"), subject: "Revert support for MERGE" },
                { committed_at: t("2024-04-06"), subject: "Implement MERGE" } ]

    buckets = described_class.new(message_times: times, commit_groups: commits).buckets

    expect(buckets.first.label).to eq("Q2 2022")
    expect(buckets.last.label).to eq("Q2 2026")
    expect(buckets.size).to eq(17)
    q3_2024 = buckets.find { |b| b.label == "Q3 2024" }
    expect([ q3_2024.commits, q3_2024.reverts ]).to eq([ 1, 1 ])
  end

  it "returns nothing without messages" do
    expect(described_class.new(message_times: [], commit_groups: []).buckets).to eq([])
  end
end
