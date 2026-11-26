require "rails_helper"

RSpec.describe Classify::SeedImport do
  it "creates seed groups, reuses names, keeps human rows" do
    existing = create(:feature_group, name: "SQL/PGQ", source: "human")
    t1, t2, t3 = create_list(:topic, 3)
    create(:feature_group_topic, topic: t3, feature_group: existing, source: "human")
    out = described_class.call([
      { "name" => "sql/pgq ", "summary" => "x", "topic_ids" => [ t1.id, t3.id ] },
      { "name" => "REPACK", "summary" => "y", "topic_ids" => [ t2.id, 999_999 ] }
    ])
    expect(out).to eq(groups: 1, memberships: 2, skipped: 2)
    expect(t1.reload.feature_group_topic).to have_attributes(feature_group: existing, source: "seed")
    expect(t3.reload.feature_group_topic.source).to eq("human")
    expect(FeatureGroup.find_by(name: "REPACK")).to have_attributes(source: "seed", summary: "y")
  end

  it "does not recreate a merged group" do
    gone = create(:feature_group, name: "REPACK")
    survivor = create(:feature_group, name: "Table rewrites")
    gone.merge_into!(survivor)
    t = create(:topic)
    out = described_class.call([ { "name" => "repack", "summary" => "y", "topic_ids" => [ t.id ] } ])
    expect(out).to eq(groups: 0, memberships: 1, skipped: 0)
    expect(t.reload.feature_group_topic.feature_group).to eq(survivor)
  end
end
