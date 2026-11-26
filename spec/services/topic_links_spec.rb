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

  it "syncs mention links from message bodies" do
    create(:message, topic: b, message_id: "t1@ex.org")
    create(:message, topic: a, message_id: "own@ex.org")
    src = create(:message, topic: a, body: "https://postgr.es/m/t1@ex.org https://postgr.es/m/own@ex.org https://postgr.es/m/nope@ex.org")
    described_class.sync_mentions!([ src.id ])
    expect(TopicLink.where(kind: "mention").pluck(:topic_id, :other_topic_id, :direction))
      .to contain_exactly([ a.id, b.id, "out" ], [ b.id, a.id, "in" ])
    src.update!(body: "no links")
    described_class.sync_mentions!([ src.id ])
    expect(TopicLink.where(kind: "mention")).to be_empty
  end

  it "ignores links into merged-away topics" do
    b.update!(merged_into_topic: c)
    create(:message, topic: b, message_id: "t2@ex.org")
    src = create(:message, topic: a, body: "https://postgr.es/m/t2@ex.org")
    described_class.sync_mentions!([ src.id ])
    expect(TopicLink.count).to eq(0)
  end

  it "syncs commitfest links between threads of one entry" do
    patch = create(:commitfest_patch)
    [ a, b, c ].each { |t| create(:commitfest_patch_topic, commitfest_patch: patch, topic: t) }
    described_class.sync_commitfest!([ patch.id ])
    expect(TopicLink.where(kind: "commitfest", ref_type: "CommitfestPatch").count).to eq(6)
    CommitfestPatchTopic.where(topic: [ b, c ]).delete_all
    described_class.sync_commitfest!([ patch.id ])
    expect(TopicLink.where(kind: "commitfest")).to be_empty
  end

  it "repoints mention and commitfest links on merge" do
    msg = create(:message, topic: a)
    described_class.link!(a, c, kind: "mention", ref: msg, direction: "out")
    described_class.link!(a, b, kind: "mention", ref: msg, direction: "out")
    described_class.repoint!(from: a, to: b)
    expect(TopicLink.pluck(:topic_id, :other_topic_id, :direction)).to contain_exactly([ b.id, c.id, "out" ], [ c.id, b.id, "in" ])
  end

  it "does not raise on non-ascii percent sequences in bodies" do
    src = create(:message, topic: a, body: "https://postgr.es/m/\u00e9%C3%A9@x.org https://postgr.es/m/bad%FF@x.org")
    expect { described_class.sync_mentions!([ src.id ]) }.not_to raise_error
  end

  it "does not raise on malformed percent sequences in bodies" do
    src = create(:message, topic: a, body: "https://postgr.es/m/abc%zz@x.org https://postgr.es/m/abc%.")
    expect { described_class.sync_mentions!([ src.id ]) }.not_to raise_error
    expect(TopicLink.count).to eq(0)
  end

  describe "commit hashes" do
    let(:sha_a) { "aaaa1111bbbb2222cccc3333dddd4444eeee5555" }
    let!(:commit_a) { create(:commit, sha: sha_a) }
    let!(:commit_b) { create(:commit, body: "Oversight in commit #{sha_a[0, 10]}.") }

    before do
      create(:commit_topic, commit: commit_a, topic: a)
      create(:commit_topic, commit: commit_b, topic: b)
    end

    it "resolves only unique prefixes" do
      create(:commit, sha: "aaaa1111ffff2222cccc3333dddd4444eeee5555")
      expect(described_class.resolve_commits([ sha_a[0, 10], "aaaa1111", "deadbeef0" ]))
        .to eq(sha_a[0, 10] => commit_a.id)
    end

    it "syncs fixes links idempotently and removes them" do
      2.times { described_class.sync_fixes!([ commit_b.id ]) }
      expect(TopicLink.where(kind: "fixes").pluck(:topic_id, :other_topic_id, :direction, :ref_type, :ref_id))
        .to contain_exactly([ b.id, a.id, "out", "Commit", commit_b.id ], [ a.id, b.id, "in", "Commit", commit_b.id ])
      commit_b.update!(body: "nothing")
      described_class.sync_fixes!([ commit_b.id ])
      expect(TopicLink.where(kind: "fixes")).to be_empty
    end

    it "makes no row for the same thread" do
      create(:commit_topic, commit: commit_b, topic: a)
      CommitTopic.where(commit: commit_b, topic: b).delete_all
      described_class.sync_fixes!([ commit_b.id ])
      expect(TopicLink.count).to eq(0)
    end

    it "makes no row for a cherry-pick copy of its own change" do
      commit_b.update!(cherry_picked_from_sha: sha_a)
      described_class.sync_fixes!([ commit_b.id ])
      expect(TopicLink.count).to eq(0)
    end

    it "reaches threads of the whole change" do
      pick = create(:commit, cherry_picked_from_sha: sha_a)
      create(:commit_topic, commit: pick, topic: c)
      described_class.sync_fixes!([ commit_b.id ])
      expect(TopicLink.where(kind: "fixes", direction: "out").pluck(:other_topic_id)).to contain_exactly(a.id, c.id)
    end

    it "links message mentions of a hash" do
      msg = create(:message, topic: c, body: "see #{sha_a[0, 12]}")
      own = create(:message, topic: a, body: "see #{sha_a[0, 12]}")
      described_class.sync_mentions!([ msg.id, own.id ])
      expect(TopicLink.where(kind: "mention").pluck(:topic_id, :other_topic_id, :direction, :ref_id))
        .to contain_exactly([ c.id, a.id, "out", msg.id ], [ a.id, c.id, "in", msg.id ])
    end
  end
end
