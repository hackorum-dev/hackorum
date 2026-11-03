require "rails_helper"

RSpec.describe Commit do
  describe "#display_version" do
    it "maps master to devel" do
      expect(described_class.new.display_version("master")).to eq("devel")
    end

    it "maps a modern stable branch to its major version" do
      expect(described_class.new.display_version("REL_18_STABLE")).to eq("18")
    end

    it "maps a pre-10 stable branch to major.minor" do
      expect(described_class.new.display_version("REL9_5_STABLE")).to eq("9.5")
    end

    it "returns the branch name unchanged when it does not match" do
      expect(described_class.new.display_version("weird")).to eq("weird")
    end
  end

  describe "#sorted_branches" do
    it "puts master first, then descending major version" do
      commit = described_class.new(branches: [ "REL_17_STABLE", "master", "REL_18_STABLE" ])
      expect(commit.sorted_branches).to eq([ "master", "REL_18_STABLE", "REL_17_STABLE" ])
    end
  end

  describe "#released?" do
    it "is false without a release" do
      expect(described_class.new(released_in: nil)).not_to be_released
    end

    it "is true with a release" do
      expect(described_class.new(released_in: "18.5")).to be_released
    end
  end

  describe ".for_topic" do
    it "returns commits linked to the topic, newest first" do
      topic = create(:topic)
      old = create(:commit, committed_at: 2.days.ago)
      new_commit = create(:commit, committed_at: 1.day.ago)
      create(:commit_topic, commit: old, topic: topic)
      create(:commit_topic, commit: new_commit, topic: topic)
      create(:commit)

      expect(described_class.for_topic(topic.id).map(&:id)).to eq([ new_commit.id, old.id ])
    end

    it "returns trailer links only unless asked for llm ones too" do
      topic = create(:topic)
      trailer = create(:commit)
      llm = create(:commit)
      create(:commit_topic, topic: topic, commit: trailer)
      create(:commit_topic, topic: topic, commit: llm, source: "llm", confidence: 0.9)

      expect(described_class.for_topic(topic.id)).to contain_exactly(trailer)
      expect(described_class.for_topic(topic.id, sources: %w[trailer llm])).to contain_exactly(trailer, llm)
    end
  end

  describe ".group_backports" do
    it "groups a backport under its canonical commit and orders branches" do
      canonical = create(:commit, sha: "aaa1", branches: [ "master" ], committed_at: 2.days.ago)
      backport = create(:commit, sha: "bbb2", branches: [ "REL_18_STABLE" ],
                                 released_in: "18.5", cherry_picked_from_sha: "aaa1",
                                 committed_at: 1.day.ago, subject: canonical.subject)

      groups = described_class.group_backports([ backport, canonical ])

      expect(groups.size).to eq(1)
      group = groups.first
      expect(group[:subject]).to eq(canonical.subject)
      expect(group[:sha]).to eq("aaa1")
      expect(group[:branches]).to eq([
        { branch: "master", version: "devel", released_in: nil, released_label: "unreleased" },
        { branch: "REL_18_STABLE", version: "18", released_in: "18.5", released_label: "18.5" }
      ])
    end

    it "lists a branch once when several members touch it, keeping the earliest release" do
      canonical = create(:commit, sha: "dup1", branches: [ "REL_17_STABLE" ], released_in: "17.9",
                                   committed_at: 3.days.ago)
      other = create(:commit, sha: "dup2", branches: [ "REL_17_STABLE" ], released_in: "17.6",
                               cherry_picked_from_sha: "dup1", committed_at: 2.days.ago)

      badges = described_class.branch_badges([ canonical, other ])

      expect(badges.map { |b| b[:branch] }).to eq([ "REL_17_STABLE" ])
      expect(badges.first[:released_label]).to eq("17.6")
    end

    it "sets released_label to the release for a released branch and unreleased otherwise" do
      canonical = create(:commit, sha: "kkk1", branches: [ "master" ], released_in: nil,
                                   committed_at: 2.days.ago)
      backport = create(:commit, sha: "lll2", branches: [ "REL_18_STABLE" ], released_in: "18.5",
                                  cherry_picked_from_sha: "kkk1", committed_at: 1.day.ago)

      group = described_class.group_backports([ canonical, backport ]).first

      labels = group[:branches].map { |b| [ b[:branch], b[:released_label] ] }
      expect(labels).to eq([ [ "master", "unreleased" ], [ "REL_18_STABLE", "18.5" ] ])
    end

    it "keeps unrelated commits in separate groups" do
      one = create(:commit, sha: "ccc3")
      two = create(:commit, sha: "ddd4")
      expect(described_class.group_backports([ one, two ]).size).to eq(2)
    end

    it "falls back to the master member when the canonical commit is not in the collection" do
      # committed_at is inverted on purpose: master is newer here, so a plain
      # min_by(&:committed_at) fallback would wrongly pick the stable member.
      stable_backport = create(:commit, sha: "fff6", branches: [ "REL_17_STABLE" ],
                                         cherry_picked_from_sha: "missing-sha",
                                         released_in: "17.4", committed_at: 2.days.ago,
                                         subject: "Fix a race in autovacuum")
      master_backport = create(:commit, sha: "eee5", branches: [ "master" ],
                                         cherry_picked_from_sha: "missing-sha",
                                         committed_at: 1.day.ago,
                                         subject: stable_backport.subject)

      groups = described_class.group_backports([ stable_backport, master_backport ])

      expect(groups.size).to eq(1)
      group = groups.first
      expect(group[:sha]).to eq("eee5")
      expect(group[:subject]).to eq(master_backport.subject)
      expect(group[:branches].map { |b| b[:branch] }).to contain_exactly("master", "REL_17_STABLE")
    end

    it "falls back to the newest stable branch when master is absent from the collection" do
      # committed_at is inverted on purpose: REL_16_STABLE is newer here, so a
      # plain min_by(&:committed_at) fallback would wrongly pick it over REL_18_STABLE.
      older = create(:commit, sha: "hhh8", branches: [ "REL_16_STABLE" ],
                              cherry_picked_from_sha: "missing-sha-2",
                              released_in: "16.9", committed_at: 2.days.ago)
      newer = create(:commit, sha: "ggg7", branches: [ "REL_18_STABLE" ],
                              cherry_picked_from_sha: "missing-sha-2",
                              released_in: "18.5", committed_at: 1.day.ago)

      groups = described_class.group_backports([ older, newer ])

      expect(groups.size).to eq(1)
      expect(groups.first[:sha]).to eq("ggg7")
    end

    it "breaks representative ties deterministically by sha" do
      same_time = 1.day.ago
      lower_sha = create(:commit, sha: "iii9", branches: [ "REL_18_STABLE" ],
                                  cherry_picked_from_sha: "missing-sha-3", committed_at: same_time)
      higher_sha = create(:commit, sha: "jjj0", branches: [ "REL_18_STABLE" ],
                                   cherry_picked_from_sha: "missing-sha-3", committed_at: same_time)

      groups = described_class.group_backports([ higher_sha, lower_sha ])

      expect(groups.first[:sha]).to eq("iii9")
    end
  end

  describe "validations" do
    it "requires a unique sha" do
      existing = create(:commit)
      expect { create(:commit, sha: existing.sha) }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end
end
