require "rails_helper"

RSpec.describe "Feature groups", type: :request do
  let(:group) { create(:feature_group, name: "Parallel vacuum", summary: "Vacuum with workers") }
  let(:topic) { create(:topic, title: "Parallel vacuum patch", last_message_at: 1.day.ago) }

  before do
    create(:feature_group_topic, feature_group: group, topic: topic)
    create(:feature_group_version, feature_group: group, major: 17, status: "shipped")
  end

  it "shows a group to guests with versions and tagged threads" do
    Classify::Setup.call!
    bot = Classify.bot_user
    NoteBuilder.new(author: bot).create!(topic: topic, body: "@global #feature #moderate")
    get feature_group_path(group.slug)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Parallel vacuum", "Vacuum with workers", "17", "shipped",
                                     "Parallel vacuum patch", "feature", "moderate")
  end

  it "shows the version line with contributing threads" do
    Classify::Setup.call!
    NoteBuilder.new(author: Classify.bot_user).create!(topic: topic, body: "@global #feature #moderate")
    group.feature_group_versions.find_by(major: 17).update!(
      role: "improved",
      details: { "topic_ids" => [ topic.id ], "size" => "moderate", "changes" => 6, "lines_added" => 2300, "lines_removed" => 400 }
    )
    get feature_group_path(group.slug)
    expect(response.body).to include("PostgreSQL 17 · shipped · improved · moderate · 6 commits · +2.3k / -400 lines")
    expect(response.body).to include("feature-group-version-threads")
  end

  it "hides merged-away topics" do
    gone = create(:topic, title: "Merged away", merged_into_topic_id: topic.id)
    create(:feature_group_topic, feature_group: group, topic: gone)
    get feature_group_path(group.slug)
    expect(response.body).not_to include("Merged away")
  end

  it "redirects a merged slug to the survivor" do
    other = create(:feature_group, name: "Survivor")
    group.merge_into!(other)
    get feature_group_path(group.slug)
    expect(response).to have_http_status(:moved_permanently)
    expect(response).to redirect_to(feature_group_path(other.slug))
  end

  it "404s an unknown slug" do
    get feature_group_path("nope")
    expect(response).to have_http_status(:not_found)
  end

  it "shows a memberless group by slug" do
    empty = create(:feature_group, name: "Empty one", source: "llm")
    get feature_group_path(empty.slug)
    expect(response).to have_http_status(:ok)
  end

  it "lists only live groups with member threads" do
    create(:feature_group, name: "Memberless", source: "llm")
    merged = create(:feature_group, name: "Merged group")
    create(:feature_group_topic, feature_group: merged, topic: create(:topic))
    merged.merge_into!(group)
    get feature_groups_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Parallel vacuum")
    expect(response.body).not_to include("Memberless")
    expect(response.body).not_to include("Merged group")
  end

  it "works without the bot user" do
    get feature_group_path(group.slug)
    expect(response).to have_http_status(:ok)
  end

  it "links the group from the topic sidebar" do
    get topic_path(topic)
    expect(response.body).to include("Feature:", feature_group_path(group.slug))
  end
end
