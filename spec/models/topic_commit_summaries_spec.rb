require "rails_helper"

RSpec.describe Topic, ".commit_summaries" do
  it "returns nothing for an empty list" do
    expect(described_class.commit_summaries([])).to eq({})
  end

  it "ignores llm links" do
    topic = create(:topic)
    create(:commit_topic, topic: topic, commit: create(:commit), source: "llm", confidence: 0.9)

    expect(described_class.commit_summaries([ topic.id ])).to eq({})
  end

  it "groups commits per topic, newest first" do
    topic = create(:topic)
    older = create(:commit, subject: "Older change", committed_at: 3.days.ago)
    newer = create(:commit, subject: "Newer change", committed_at: 1.day.ago,
                            branches: [ "REL_18_STABLE" ], released_in: "18.5")
    create(:commit_topic, commit: older, topic: topic)
    create(:commit_topic, commit: newer, topic: topic)

    summaries = described_class.commit_summaries([ topic.id ])

    expect(summaries.keys).to eq([ topic.id ])
    expect(summaries[topic.id][:groups].size).to eq(2)
    expect(summaries[topic.id][:groups].first[:subject]).to eq("Newer change")
    expect(summaries[topic.id][:groups].first[:branches]).to eq([
      { branch: "REL_18_STABLE", version: "18", released_in: "18.5", released_label: "18.5" }
    ])
  end

  it "collapses a backport into one group" do
    topic = create(:topic)
    canonical = create(:commit, sha: "aaa1", subject: "Shared change", branches: [ "master" ],
                                committed_at: 2.days.ago)
    backport = create(:commit, sha: "bbb2", subject: "Shared change", branches: [ "REL_18_STABLE" ],
                               released_in: "18.5", cherry_picked_from_sha: "aaa1",
                               committed_at: 1.day.ago)
    create(:commit_topic, commit: canonical, topic: topic)
    create(:commit_topic, commit: backport, topic: topic)

    summaries = described_class.commit_summaries([ topic.id ])

    expect(summaries[topic.id][:groups].size).to eq(1)
    expect(summaries[topic.id][:groups].first[:branches].map { |b| b[:branch] })
      .to eq([ "master", "REL_18_STABLE" ])
  end

  it "omits topics with no commits" do
    topic = create(:topic)
    expect(described_class.commit_summaries([ topic.id ])).to eq({})
  end

  it "collapses a canonical commit plus two backports into one group" do
    topic = create(:topic)
    canonical = create(:commit, sha: "mmm1", subject: "Shared change", branches: [ "master" ],
                                committed_at: 3.days.ago)
    backport_17 = create(:commit, sha: "nnn2", subject: "Shared change", branches: [ "REL_17_STABLE" ],
                                  released_in: "17.4", cherry_picked_from_sha: "mmm1",
                                  committed_at: 2.days.ago)
    backport_18 = create(:commit, sha: "ooo3", subject: "Shared change", branches: [ "REL_18_STABLE" ],
                                  released_in: "18.5", cherry_picked_from_sha: "mmm1",
                                  committed_at: 1.day.ago)
    create(:commit_topic, commit: canonical, topic: topic)
    create(:commit_topic, commit: backport_17, topic: topic)
    create(:commit_topic, commit: backport_18, topic: topic)

    summaries = described_class.commit_summaries([ topic.id ])

    expect(summaries[topic.id][:groups].size).to eq(1)
    expect(summaries[topic.id]).not_to have_key(:count)
  end
end
