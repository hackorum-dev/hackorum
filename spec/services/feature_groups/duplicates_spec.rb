require "rails_helper"

RSpec.describe FeatureGroups::Duplicates do
  def group(name)
    create(:feature_group, name: name)
  end

  def member(g)
    create(:feature_group_topic, feature_group: g, topic: create(:topic)).topic
  end

  def link(t1, t2, kind: "mention")
    ref = create(:commit)
    create(:topic_link, topic: t1, other_topic: t2, kind: kind, direction: "out", ref: ref)
    create(:topic_link, topic: t2, other_topic: t1, kind: kind, direction: "in", ref: ref)
  end

  it "lists similar names" do
    a = group("OAuth authentication")
    b = group("OAuth authentication support")
    pair = described_class.pairs.first
    expect([ pair[:a], pair[:b] ]).to eq([ a, b ].sort_by(&:id))
    expect(pair[:similarity]).to be >= 0.45
    expect(pair[:links]).to eq(0)
  end

  it "lists unrelated names with two topic links" do
    a = group("Zebra stripes")
    b = group("Quantum flux")
    a1 = member(a)
    a2 = member(a)
    b1 = member(b)
    link(a1, b1)
    link(a2, b1)
    pair = described_class.pairs.first
    expect(pair[:links]).to eq(2)
    expect(pair[:a].id).to be < pair[:b].id
  end

  it "counts a topic pair once across mirrors and kinds" do
    a = group("Zebra stripes")
    b = group("Quantum flux")
    a1 = member(a)
    b1 = member(b)
    link(a1, b1)
    link(a1, b1, kind: "commit")
    expect(described_class.pairs).to be_empty
  end

  it "skips one link with low similarity" do
    a = group("Zebra stripes")
    b = group("Quantum flux")
    link(member(a), member(b))
    expect(described_class.pairs).to be_empty
  end

  it "skips merged groups" do
    a = group("OAuth authentication")
    b = group("OAuth authentication support")
    b.merge_into!(a)
    expect(described_class.pairs).to be_empty
  end

  it "hides dismissed pairs" do
    a = group("OAuth authentication")
    b = group("OAuth authentication support")
    FeatureGroupDismissedPair.create!(low_id: [ a.id, b.id ].min, high_id: [ a.id, b.id ].max)
    expect(described_class.pairs).to be_empty
  end

  it "orders by links then similarity and honors limit" do
    a = group("OAuth authentication")
    b = group("OAuth authentication support")
    c = group("Zebra stripes")
    d = group("Quantum flux")
    c1 = member(c)
    c2 = member(c)
    d1 = member(d)
    link(c1, d1)
    link(c2, d1)
    pairs = described_class.pairs
    expect(pairs.map { |p| [ p[:a].id, p[:b].id ] }).to eq([ [ c.id, d.id ], [ a.id, b.id ] ])
    expect(described_class.pairs(limit: 1).size).to eq(1)
  end
end
