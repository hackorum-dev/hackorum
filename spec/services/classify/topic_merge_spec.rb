require "rails_helper"

RSpec.describe Classify::TopicMerge do
  let(:admin) { create(:user, admin: true) }

  before { Classify::Setup.call! }

  def merge(src, dst)
    TopicMergeService.new(source_topic: src, target_topic: dst, merged_by: admin).call
  end

  it "keeps the target's note and membership, else takes the source's" do
    src, dst = create_list(:topic, 2)
    Classify::BotNote.new(src).write!(%w[bug])
    Classify::BotNote.new(dst).write!(%w[feature minor])
    g1 = create(:feature_group)
    create(:feature_group_topic, topic: src, feature_group: g1)
    merge(src, dst)
    expect(Note.where(topic: dst, author: Classify.bot_user).count).to eq(1)
    expect(Classify::BotNote.tags_by_topic([ dst.id ])[dst.id]).to eq(%w[feature minor])
    expect(dst.reload.feature_group_topic.feature_group).to eq(g1)
  end

  it "keeps the target's membership over the source's" do
    src, dst = create_list(:topic, 2)
    g1, g2 = create_list(:feature_group, 2)
    create(:feature_group_topic, topic: src, feature_group: g1)
    create(:feature_group_topic, topic: dst, feature_group: g2)
    merge(src, dst)
    expect(dst.reload.feature_group_topic.feature_group).to eq(g2)
    expect(FeatureGroupTopic.where(topic_id: src.id)).to be_empty
  end

  it "moves the source's bot note when the target has none" do
    src, dst = create_list(:topic, 2)
    Classify::BotNote.new(src).write!(%w[bug])
    merge(src, dst)
    expect(Classify::BotNote.tags_by_topic([ dst.id ])[dst.id]).to eq(%w[bug])
  end

  it "refreshes versions of the groups after the commits moved" do
    src, dst = create_list(:topic, 2)
    Classify::BotNote.new(src).write!(%w[feature major])
    create(:commit_topic, topic: src, commit: create(:commit, branches: %w[REL_19_STABLE master]))
    g1, g2 = create_list(:feature_group, 2)
    create(:feature_group_topic, topic: src, feature_group: g1)
    FeatureGroups::Versions.refresh!([ g1.id ])
    expect(g1.feature_group_versions.pluck(:major)).to eq([ 19 ])
    Classify::BotNote.new(dst).write!(%w[feature minor])
    create(:feature_group_topic, topic: dst, feature_group: g2)

    merge(src, dst)

    expect(g1.feature_group_versions.pluck(:major)).to be_empty
    expect(g2.feature_group_versions.pluck(:major)).to eq([ 19 ])
  end

  it "moves the membership and recomputes from the merged commits" do
    src, dst = create_list(:topic, 2)
    Classify::BotNote.new(dst).write!(%w[feature major])
    create(:commit_topic, topic: src, commit: create(:commit, branches: %w[REL_19_STABLE master]))
    g1 = create(:feature_group)
    create(:feature_group_topic, topic: src, feature_group: g1)

    merge(src, dst)

    expect(g1.feature_group_versions.pluck(:major)).to eq([ 19 ])
  end
end
