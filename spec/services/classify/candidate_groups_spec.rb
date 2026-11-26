require "rails_helper"

RSpec.describe Classify::CandidateGroups do
  let(:topic) { create(:topic, title: "Logical replication of sequences") }

  def member(group, last_message_at: nil, source: "llm")
    t = create(:topic)
    t.update_columns(last_message_at:) if last_message_at
    create(:feature_group_topic, topic: t, feature_group: group, source:)
    t
  end

  it "orders candidate groups and resolves merges" do
    survivor = create(:feature_group, name: "Survivor")
    merged = create(:feature_group, name: "Logical replication of sequences, merged", merged_into: survivor)
    linked = member(merged)
    create(:topic_link, topic:, other_topic: linked)
    linked_live = create(:feature_group, name: "Zeta")
    create(:topic_link, topic:, other_topic: member(linked_live), kind: "mention", direction: "out")
    own = create(:feature_group, name: "Own")
    create(:feature_group_topic, topic:, feature_group: own, source: "seed")
    similar = create(:feature_group, name: "Logical replication of sequences and DDL")
    active = create(:feature_group, name: "Active")
    member(active, last_message_at: 2.days.ago)
    member(create(:feature_group, name: "Stale"), last_message_at: 2.years.ago)
    create(:feature_group, name: "Unrelated")

    expect(described_class.new(topic).call).to eq([ survivor, linked_live, own, similar, active ])
  end

  it "lists a group once and survivors only" do
    group = create(:feature_group, name: "Logical replication of sequences")
    create(:topic_link, topic:, other_topic: member(group, last_message_at: 1.day.ago))
    create(:feature_group, name: "Logical replication of sequences v2", merged_into: group)

    expect(described_class.new(topic).call).to eq([ group ])
  end

  it "includes the topic's own human group" do
    pick = create(:feature_group, name: "Admin pick")
    create(:feature_group_topic, topic:, feature_group: pick, source: "human")

    expect(described_class.new(topic).call).to eq([ pick ])
  end

  it "respects the cap" do
    stub_const("Classify::CandidateGroups::CANDIDATE_CAP", 2)
    groups = 3.times.map { |i| create(:feature_group, name: "Active #{i}") }
    groups.each_with_index { |g, i| member(g, last_message_at: (i + 1).days.ago) }

    expect(described_class.new(topic).call).to eq(groups.first(2))
  end
end
