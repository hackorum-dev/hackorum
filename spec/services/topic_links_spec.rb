require "rails_helper"

RSpec.describe TopicLinks do
  let(:a) { create(:topic) }
  let(:b) { create(:topic) }
  let(:c) { create(:topic) }
  let(:commit) { create(:commit) }

  it "mirrors directed links" do
    msg = create(:message, topic: a)
    described_class.link!(a, b, kind: "mention", ref: msg, direction: "out")
    described_class.link!(a, b, kind: "mention", ref: msg, direction: "out")
    expect(TopicLink.pluck(:topic_id, :other_topic_id, :direction)).to contain_exactly([ a.id, b.id, "out" ], [ b.id, a.id, "in" ])
  end

  it "syncs commit links from commit_topics" do
    [ a, b, c ].each { |t| create(:commit_topic, topic: t, commit: commit) }
    described_class.sync_commits!([ commit.id ])
    expect(TopicLink.where(kind: "commit").count).to eq(6)
    expect(TopicLink.where(topic: a).pluck(:other_topic_id, :direction)).to contain_exactly([ b.id, "both" ], [ c.id, "both" ])

    CommitTopic.where(topic: [ b, c ]).delete_all
    described_class.sync_commits!([ commit.id ])
    expect(TopicLink.count).to eq(0)
  end
end
