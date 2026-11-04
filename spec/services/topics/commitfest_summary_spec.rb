require "rails_helper"

RSpec.describe Topics::CommitfestSummary do
  let(:topic) { create(:topic) }

  def cf(name, months_ago)
    create(:commitfest, name: name, start_date: (months_ago + 1).months.ago, end_date: months_ago.months.ago)
  end

  def patch(**attrs)
    create(:commitfest_patch, :with_topic, topic: topic, **attrs)
  end

  it "does not call a moved patch closed" do
    p = patch
    create(:commitfest_patch_commitfest, commitfest_patch: p, commitfest: cf("PG19-Final", 0), status: "Moved to different CF")

    summary = described_class.new(topic)
    expect(summary.all_closed?).to be(false)
    expect(summary.open_patches).to eq([])
  end

  it "takes status from the latest commitfest and keeps the history" do
    p = patch(title: "Add SPLIT PARTITION", reviewers: "Robert Haas, Justin Pryzby", committer: " Alexander Korotkov ")
    create(:commitfest_patch_commitfest, commitfest_patch: p, commitfest: cf("2022-07", 30), status: "Moved to different CF")
    create(:commitfest_patch_commitfest, commitfest_patch: p, commitfest: cf("2022-09", 28), status: "Moved to different CF")
    create(:commitfest_patch_commitfest, commitfest_patch: p, commitfest: cf("PG19-4", 1), status: "Committed", ci_status: "score")

    summary = described_class.new(topic)
    entry = summary.patches.sole

    expect(entry.status).to eq("Committed")
    expect(entry.commitfest_name).to eq("PG19-4")
    expect(entry.history.map { |h| h[:name] }).to eq(%w[2022-07 2022-09 PG19-4])
    expect(entry.reviewers).to eq([ "Robert Haas", "Justin Pryzby" ])
    expect(entry.committer).to eq("Alexander Korotkov")
    expect(summary.all_closed?).to be(true)
    expect(summary.moved_count).to eq(2)
    expect(summary.latest_commitfest_name).to eq("PG19-4")
  end

  it "reports open patches" do
    p = patch
    create(:commitfest_patch_commitfest, commitfest_patch: p, commitfest: cf("PG20-1", 0), status: "Needs review", ci_status: "needs_rebase")

    summary = described_class.new(topic)
    expect(summary.all_closed?).to be(false)
    expect(summary.open_patches.map(&:status)).to eq([ "Needs review" ])
    expect(summary.open_patches.first.ci_status).to eq("needs_rebase")
  end

  it "is empty for a topic without commitfest rows" do
    expect(described_class.new(topic).any?).to be(false)
  end
end
