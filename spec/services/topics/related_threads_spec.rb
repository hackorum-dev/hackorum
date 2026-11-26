require "rails_helper"

RSpec.describe Topics::RelatedThreads do
  let(:commit) { create(:commit) }
  let(:bug) { create(:topic) }
  let(:patch) { create(:topic).tap { |t| create(:message, topic: t, is_patch_submission: true) } }

  before do
    [ bug, patch ].each { |t| create(:commit_topic, topic: t, commit: commit) }
    TopicLinks.sync_commits!([ commit.id ])
  end

  it "labels a shared commit and the roles" do
    create(:commit_verdict, patchset_run: create(:patchset_run, topic: patch), commit: commit, verdict: "as_is")
    create(:commit_verdict, patchset_run: create(:patchset_run, topic: bug), commit: commit, verdict: "other_thread")
    expect(described_class.new(bug).entries.sole).to include(topic: patch, label: "same commit", role: "patch thread")
    expect(described_class.new(patch).entries.sole).to include(topic: bug, role: "report / discussion")
  end

  it "has no role without verdicts and counts several commits" do
    second = create(:commit)
    [ bug, patch ].each { |t| create(:commit_topic, topic: t, commit: second) }
    TopicLinks.sync_commits!([ second.id ])
    expect(described_class.new(bug).entries.sole).to include(label: "2 shared commits", role: nil)
  end

  it "labels fixes links" do
    other = create(:topic)
    TopicLinks.link!(bug, other, kind: "fixes", ref: create(:commit), direction: "out")
    expect(described_class.new(bug).entries.find { |e| e[:topic] == other }[:label]).to eq("follow-up of")
    expect(described_class.new(other).entries.map { |e| e[:label] }).to include("followed up in")
  end

  it "labels directed mentions" do
    other = create(:topic)
    TopicLinks.link!(bug, other, kind: "mention", ref: create(:message, topic: bug), direction: "out")
    expect(described_class.new(other).entries.map { |e| e[:label] }).to include("mentioned in")
  end

  it "maps commit groups to other threads" do
    create(:commit_verdict, patchset_run: create(:patchset_run, topic: patch), commit: commit, verdict: "as_is")
    group = { sha: commit.sha, commit_ids: [ commit.id ] }
    other = { sha: "x", commit_ids: [ -1 ] }
    result = described_class.new(bug).also_in([ group, other ])
    expect(result.keys).to eq([ commit.sha ])
    expect(result[commit.sha]).to eq([ { topic: patch, verdict: "as_is" } ])
  end

  it "counts a change with backports once and finds the canonical verdict" do
    backports = create_list(:commit, 2, cherry_picked_from_sha: commit.sha)
    backports.each { |b| [ bug, patch ].each { |t| create(:commit_topic, topic: t, commit: b) } }
    TopicLinks.sync_commits!(backports.map(&:id))
    create(:commit_verdict, patchset_run: create(:patchset_run, topic: patch), commit: commit, verdict: "as_is")
    create(:commit_verdict, patchset_run: create(:patchset_run, topic: bug), commit: commit, verdict: "other_thread")
    rel = described_class.new(bug)
    expect(rel.entries.sole).to include(label: "same commit", role: "patch thread")
    group = { sha: commit.sha, commit_ids: backports.map(&:id) }
    expect(rel.also_in([ group ])[commit.sha]).to eq([ { topic: patch, verdict: "as_is" } ])
  end

  describe "feature group" do
    let(:group) { create(:feature_group) }
    let(:sibling) { create(:topic) }

    before do
      create(:feature_group_topic, feature_group: group, topic: bug)
      create(:feature_group_topic, feature_group: group, topic: sibling)
    end

    it "exposes the group and lists siblings as same feature" do
      rel = described_class.new(bug)
      expect(rel.feature_group).to eq(group)
      expect(rel.entries.find { |e| e[:topic] == sibling }[:label]).to eq("same feature")
    end

    it "appends to an existing label" do
      TopicLinks.link!(bug, sibling, kind: "mention", ref: create(:message, topic: bug), direction: "out")
      entry = described_class.new(bug).entries.find { |e| e[:topic] == sibling }
      expect(entry[:label]).to eq("mentions, same feature")
    end

    it "has no group for ungrouped topics" do
      expect(described_class.new(create(:topic)).feature_group).to be_nil
    end

    it "lists linked threads before unlinked siblings" do
      create(:message, topic: sibling, is_patch_submission: true, created_at: 1.minute.from_now)
      linked_sibling = create(:topic)
      create(:feature_group_topic, feature_group: group, topic: linked_sibling)
      TopicLinks.link!(bug, linked_sibling, kind: "mention", ref: create(:message, topic: bug), direction: "out")
      expect(described_class.new(bug).entries.map { |e| e[:topic] }).to eq([ patch, linked_sibling, sibling ])
    end

    it "ignores merged-away siblings" do
      sibling.update!(merged_into_topic_id: bug.id)
      expect(described_class.new(bug).entries.map { |e| e[:topic] }).not_to include(sibling)
    end
  end
end
