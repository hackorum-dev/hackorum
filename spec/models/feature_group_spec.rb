require "rails_helper"

RSpec.describe FeatureGroup do
  it "normalizes names" do
    expect(FeatureGroup.normalize_name("  SQL/PGQ  ")).to eq(FeatureGroup.normalize_name("sql/pgq"))
    expect(FeatureGroup.normalize_name("FOR  PORTION OF")).to eq("for portion of")
  end

  it "builds unique slugs" do
    expect(create(:feature_group, name: "SQL/PGQ").slug).to eq("sql-pgq")
    expect(create(:feature_group, name: "SQL PGQ").slug).to eq("sql-pgq-2")
  end

  it "merges members and follows merge chains" do
    a, b, c = create_list(:feature_group, 3)
    t = create(:feature_group_topic, feature_group: a)
    a.merge_into!(b)
    b.merge_into!(c)
    expect(t.reload.feature_group).to eq(c)
    expect(a.reload.surviving).to eq(c)
    expect(FeatureGroup.find_by_normalized_name(a.name)).to eq(c)
  end

  it "prefers a live group over a merged one with the same name" do
    live = create(:feature_group, name: "REPACK")
    gone = create(:feature_group, name: "repack ")
    gone.merge_into!(create(:feature_group))
    expect(FeatureGroup.find_by_normalized_name("Repack")).to eq(live)
  end

  it "finds live groups by normalized name" do
    g = create(:feature_group, name: "FOR PORTION OF")
    expect(FeatureGroup.find_by_normalized_name(" for  portion of ")).to eq(g)
  end

  it "reports human membership" do
    expect(build(:feature_group_topic, source: "human")).to be_human
    expect(build(:feature_group_topic)).not_to be_human
  end
end
