require "rails_helper"

RSpec.describe Lineage::MultithreadRepair do
  let(:commit) { create(:commit) }
  let(:a) { create(:topic) }
  let(:b) { create(:topic) }

  before do
    [ a, b ].each { |t| create(:commit_topic, topic: t, commit: commit, source: "trailer") }
    create(:commit_verdict, patchset_run: create(:patchset_run, topic: a), commit: commit, verdict: "as_is")
    create(:commit_verdict, patchset_run: create(:patchset_run, topic: b), commit: commit, verdict: "from_discussion")
  end

  it "plans and applies rechecks for both threads" do
    plan = described_class.new.plan
    expect(plan).to include(commits: 1, topics: 2, pairs: { "as_is+from_discussion" => 1 })
    expect(described_class.new.apply!).to eq(2)
    expect(LineageRecheck.open.pluck(:topic_id)).to contain_exactly(a.id, b.id)
    expect(described_class.new.apply!).to eq(0)
  end

  it "ignores commits with one committed verdict" do
    CommitVerdict.where(topic: b).update_all(verdict: "not_this_thread")
    expect(described_class.new.plan[:commits]).to eq(0)
  end

  it "ignores merged topics" do
    b.update!(merged_into_topic_id: a.id)
    expect(described_class.new.plan[:commits]).to eq(0)
  end

  it "ignores topics not trailer-linked to the commit" do
    CommitTopic.where(topic: b).update_all(source: "llm")
    expect(described_class.new.plan[:commits]).to eq(0)
  end
end
