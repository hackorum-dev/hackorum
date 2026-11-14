require "rails_helper"

RSpec.describe Lineage::Updates do
  let(:topic) { create(:topic) }
  let!(:v1) { create(:message, topic: topic, created_at: 3.days.ago, is_patch_submission: true) }
  let(:judged) { create(:commit) }
  let!(:run) do
    create(:commit_topic, topic: topic, commit: judged, source: "trailer")
    create(:patchset_run, topic: topic, status: "done", mode: "trailer", through_message: v1, created_at: 2.days.ago).tap do |r|
      create(:commit_verdict, patchset_run: r, commit: judged)
    end
  end

  def link(commit) = create(:commit_topic, topic: topic, commit: commit, source: "trailer")

  it "lists commits with an open recheck" do
    c = create(:commit)
    create(:lineage_recheck, topic: topic, commit: c)
    create(:lineage_recheck, topic: topic, commit: create(:commit), done_at: Time.current)
    expect(described_class.recheck_commits(topic)).to eq([ c ])
  end

  it "finds trailer commits the run has no verdict for" do
    fresh = create(:commit)
    link(fresh)
    expect(described_class.new_commits(topic, run)).to eq([ fresh ])
  end

  it "counts a backport of a judged commit as judged" do
    link(create(:commit, cherry_picked_from_sha: judged.sha, branches: [ "REL_17_STABLE" ]))
    expect(described_class.new_commits(topic, run)).to eq([])
  end

  it "counts a verdict on a backport as judging the linked master commit" do
    master = create(:commit)
    backport = create(:commit, cherry_picked_from_sha: master.sha, branches: [ "REL_17_STABLE" ])
    create(:commit_verdict, patchset_run: run, commit: backport)
    link(master)
    expect(described_class.new_commits(topic, run)).to eq([])
  end

  it "counts a verdict on the backport a chained cherry-pick came from" do
    master = create(:commit)
    b1 = create(:commit, cherry_picked_from_sha: master.sha, branches: [ "REL_17_STABLE" ])
    b2 = create(:commit, cherry_picked_from_sha: b1.sha, branches: [ "REL_16_STABLE" ])
    create(:commit_verdict, patchset_run: run, commit: b1)
    link(b2)
    expect(described_class.new_commits(topic, run)).to eq([])
  end

  it "ignores llm links" do
    create(:commit_topic, topic: topic, commit: create(:commit), source: "llm", confidence: 0.9)
    expect(described_class.new_commits(topic, run)).to eq([])
  end

  describe ".new_patchset_ids" do
    let(:late) { create(:message, topic: topic, created_at: 4.days.ago, is_patch_submission: true) }
    let(:later) { create(:message, topic: topic, created_at: 1.day.ago, is_patch_submission: true) }

    it "takes what the run did not see" do
      run.update!(bundle_index: { "patchsets" => [ { "message_id" => v1.id }, { "message_id" => later.id } ] })
      expect(described_class.new_patchset_ids(run, [ v1, late, later ])).to eq(Set[late.id])
    end

    it "falls back to dates without a patchset list" do
      expect(described_class.new_patchset_ids(run, [ v1, late, later ])).to eq(Set[later.id])
      run.update!(through_message: nil)
      expect(described_class.new_patchset_ids(run, [ v1, late ])).to eq(Set[v1.id, late.id])
    end
  end

  describe ".new_message?" do
    it "is new when after the through message by id or by date" do
      older = create(:message, topic: topic, created_at: 5.days.ago)
      through = create(:message, topic: topic, created_at: 4.days.ago)
      late = create(:message, topic: topic, created_at: 6.days.ago)
      run.update!(through_message: through)
      expect(described_class.new_message?(run, through)).to be(false)
      expect(described_class.new_message?(run, older)).to be(false)
      expect(described_class.new_message?(run, v1)).to be(true)
      expect(described_class.new_message?(run, late)).to be(true)
      run.update!(through_message: nil)
      expect(described_class.new_message?(run, older)).to be(true)
    end
  end
end
