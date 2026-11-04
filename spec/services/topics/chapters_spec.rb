require "rails_helper"

RSpec.describe Topics::Chapters do
  Msg = Struct.new(:id, :created_at) unless defined?(Msg)

  def msgs(*spec)
    id = 0
    spec.flat_map do |start, count, step|
      t = Time.zone.parse(start)
      Array.new(count) { |i| Msg.new(id += 1, t + (i * (step || 1)).hours) }
    end
  end

  it "has no chapters for short threads" do
    expect(described_class.new(msgs([ "2026-01-01", 59 ])).chapters).to eq([])
  end

  it "splits on 45 day gaps and names by date" do
    list = msgs([ "2022-05-31", 30, 24 ], [ "2024-04-01", 40, 12 ])
    chapters = described_class.new(list).chapters

    expect(chapters.map(&:size)).to eq([ 30, 40 ])
    expect(chapters.map(&:label)).to eq([ "May - Jun 2022", "Apr 2024" ])
    expect(described_class.new(list).index_of(list.last.id)).to eq(1)
  end

  it "names a full calendar year by the year" do
    list = msgs([ "2025-01-03", 31, 24 * 12 ], [ "2027-01-01", 40, 1 ])
    expect(described_class.new(list).chapters.first.label).to eq("2025")
  end

  it "splits oversize chapters at month boundaries" do
    list = msgs([ "2024-04-01", 90, 6 ], [ "2024-05-01", 90, 6 ], [ "2024-06-01", 20, 6 ])
    expect(described_class.new(list).chapters.map(&:size)).to eq([ 90, 90, 20 ])

    list = msgs([ "2024-04-01", 90, 6 ], [ "2024-05-01", 70, 6 ], [ "2024-06-01", 20, 6 ])
    expect(described_class.new(list).chapters.map(&:size)).to eq([ 90, 90 ])
  end

  it "assigns commits to chapters by date" do
    list = msgs([ "2022-05-31", 30, 24 ], [ "2024-04-01", 40, 12 ])
    commits = [ { committed_at: Time.zone.parse("2022-01-01"), subject: "early" },
                { committed_at: Time.zone.parse("2023-01-01"), subject: "gap" },
                { committed_at: Time.zone.parse("2024-04-06"), subject: "Revert x" } ]
    chapters = described_class.new(list, commit_groups: commits).chapters

    expect(chapters.map(&:commits).map(&:size)).to eq([ 2, 1 ])
    expect(chapters.map(&:reverts)).to eq([ 0, 1 ])
  end
end
