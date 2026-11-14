require "rails_helper"

RSpec.describe Lineage::OtherThreads do
  let(:commit) { create(:commit) }
  let(:bug) { create(:topic, title: "BUG #1").tap { |t| create(:message, topic: t) } }
  let(:patch) { create(:topic, title: "[PATCH] fix").tap { |t| create(:message, topic: t) } }
  let!(:p1) { create(:message, topic: patch, is_patch_submission: true, created_at: 1.day.ago) }

  before do
    create(:commit_topic, commit: commit, topic: bug, source: "trailer")
    create(:commit_topic, commit: commit, topic: patch, source: "trailer")
  end

  it "lists the other thread without verdict when unjudged" do
    out = described_class.new(bug).call([ commit ])
    entry = out.fetch(commit.id).sole
    expect(entry).to include("topic_id" => patch.id, "title" => "[PATCH] fix", "patchset_count" => 1, "verdict" => nil)
    expect(entry["patchsets"].sole["message_id"]).to eq(p1.id)
  end

  it "includes the current verdict of the other thread" do
    run = create(:patchset_run, topic: patch)
    create(:commit_verdict, patchset_run: run, commit: commit, verdict: "as_is", source_message: p1, confidence: 0.97)
    v = described_class.new(bug).call([ commit ]).fetch(commit.id).sole["verdict"]
    expect(v).to include("verdict" => "as_is", "source_message_id" => p1.id, "confidence" => 0.97)
  end

  it "skips merged topics" do
    patch.update!(merged_into_topic_id: create(:topic).id)
    expect(described_class.new(bug).call([ commit ]).fetch(commit.id)).to eq([])
  end

  it "skips llm-only links" do
    other = create(:topic).tap { |t| create(:message, topic: t) }
    create(:commit_topic, commit: commit, topic: other, source: "llm")
    ids = described_class.new(bug).call([ commit ]).fetch(commit.id).map { |e| e["topic_id"] }
    expect(ids).to eq([ patch.id ])
  end

  it "finds the verdict through a backport" do
    backport = create(:commit, cherry_picked_from_sha: commit.sha)
    run = create(:patchset_run, topic: patch)
    create(:commit_verdict, patchset_run: run, commit: commit, verdict: "modified", change_level: "light")
    CommitTopic.where(commit: commit, topic: bug).update_all(commit_id: backport.id)
    out = described_class.new(bug).call([ commit ], backports: { commit.id => [ backport ] })
    expect(out.fetch(commit.id).sole["verdict"]["verdict"]).to eq("modified")
  end
end
