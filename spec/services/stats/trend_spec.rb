require "rails_helper"

RSpec.describe Stats::Trend do
  let(:p1) { instance_double(Stats::Period::Year, key: "2024", label: "2024", open?: false) }
  let(:p2) { instance_double(Stats::Period::Year, key: "2025", label: "2025", open?: false) }
  let(:p3) { instance_double(Stats::Period::Year, key: "2026", label: "2026", open?: true) }

  def overview(commits:, non_committers:, top5:, with_thread:, crediting:, llm:, covered: 10, as_is: 5)
    { llm: llm,
      code: { commits: commits, authors: 3, reviewers: 2, lines_added: 10, lines_removed: 5,
              committers: { count: 4, top5_share: top5 }, committer_steps: { "10+" => 2 } },
      discussion: { threads: 7, messages: 70, people: 9, patch_mails: 12, with_thread: with_thread, age_median_days: 40 },
      lineage: { covered: covered, cf_commits: commits / 2, cf_entries: 3,
                 verdicts: { as_is: as_is, modified: 3, partial: 1, from_discussion: 1 }, versions: { median: 3 } },
      reviews: { crediting: crediting, by_others: { non_committers: non_committers }, alone: { count: 1, of: 4 } } }
  end

  let(:overviews) do
    { "2024" => overview(commits: 100, non_committers: 13, top5: 75, with_thread: 62, crediting: 14, llm: false),
      "2025" => overview(commits: 200, non_committers: 80, top5: 45, with_thread: 182, crediting: 122, llm: true),
      "2026" => overview(commits: 0, non_committers: 0, top5: 0, with_thread: 0, crediting: 0, llm: true) }
  end

  subject(:trend) { described_class.new("year") }

  before do
    allow(Stats::Period::Year).to receive(:available).and_return([ p3, p2, p1 ])
    allow(trend).to receive(:overview_for) { |p| overviews[p.key] }
    allow(trend).to receive(:first_timers_for).and_return(5)
  end

  def series(group, key) = trend.to_h[group].find { |s| s[:key] == key }

  it "maps url segments to kinds" do
    expect(described_class.kind_for("releases")).to eq("release")
    expect(described_class.kind_for("cycles")).to eq("cycle")
    expect(described_class.kind_for("nope")).to be_nil
  end

  it "lists periods oldest first and flags the open one" do
    expect(trend.to_h[:periods]).to eq([ { key: "2024", label: "2024", open: false },
                                         { key: "2025", label: "2025", open: false },
                                         { key: "2026", label: "2026", open: true } ])
  end

  it "turns overview numbers into shares, nil on an empty period" do
    s = series(:shifts, "non_committer_authored")
    expect(s[:unit]).to eq("%")
    expect(s[:lines].first[:values]).to eq([ 13.0, 40.0, nil ])
    expect(series(:shifts, "top5_share")[:lines].first[:values]).to eq([ 75, 45, 0 ])
    expect(series(:shifts, "with_thread")[:lines].first[:values]).to eq([ 62.0, 91.0, nil ])
  end

  it "uses closed periods for the headline" do
    expect(series(:shifts, "non_committer_authored")[:headline])
      .to eq(from: 13.0, from_label: "2024", to: 40.0, to_label: "2025")
  end

  it "draws the committing core as two lines" do
    expect(series(:shifts, "committing_core")[:lines].map { |l| l[:label] }).to eq([ "10+ commits", "all committers" ])
  end

  it "leaves gaps where the LLM data is not shown" do
    s = series(:llm, "as_posted")
    expect(s[:lines].first[:values]).to eq([ nil, 50.0, 50.0 ])
    expect(s[:headline]).to be_nil
    expect(trend.to_h[:llm_from]).to eq("2025")
  end

  it "has the volume series" do
    expect(trend.to_h[:volume].map { |s| s[:key] })
      .to eq(%w[commits lines threads messages posters patch_mails authors reviewers committers cf_entries])
    expect(series(:volume, "lines")[:lines].first[:values]).to eq([ 15, 15, 15 ])
    overviews["2024"][:code].merge!(lines_added: nil, lines_removed: nil)
    expect(series(:volume, "lines")[:lines].first[:values].first).to be_nil
  end
end
