require "rails_helper"

RSpec.describe "Admin::FeatureGroups", type: :request do
  let(:admin) { create(:user, admin: true) }
  let(:group) { create(:feature_group, name: "SQL PGQ") }
  let(:other) { create(:feature_group, name: "Other") }
  let(:topic) { create(:topic) }

  before do
    Classify::Setup.call!
    sign_in_as(admin)
  end

  it "is admin only" do
    sign_in_as(create(:user))
    get admin_feature_groups_path
    expect(response).not_to have_http_status(:ok)
  end

  it "lists and searches groups" do
    group
    other
    get admin_feature_groups_path, params: { q: "pgq" }
    expect(response.body).to include("SQL PGQ")
    expect(response.body).not_to include("Other")
  end

  it "shows members with tags" do
    create(:feature_group_topic, feature_group: group, topic: topic)
    Classify::BotNote.new(topic).write!(%w[feature major])
    get admin_feature_group_path(group)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(topic.title, "#feature")
  end

  it "renders edit" do
    get edit_admin_feature_group_path(group)
    expect(response).to have_http_status(:ok)
  end

  it "renames as human" do
    patch admin_feature_group_path(group), params: { feature_group: { name: "SQL/PGQ" } }
    expect(group.reload).to have_attributes(name: "SQL/PGQ", source: "human")
  end

  it "re-renders on invalid update" do
    patch admin_feature_group_path(group), params: { feature_group: { name: "" } }
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it "rejects a blank slug" do
    slug = group.slug
    patch admin_feature_group_path(group), params: { feature_group: { name: "X", slug: "" } }
    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to include("Slug can")
    expect(group.reload.slug).to eq(slug)
  end

  it "merges into another group" do
    post merge_admin_feature_group_path(group), params: { target_id: other.id }
    expect(group.reload.merged_into_id).to eq(other.id)
  end

  it "rejects merge into itself" do
    post merge_admin_feature_group_path(group), params: { target_id: group.id }
    expect(group.reload.merged_into_id).to be_nil
    expect(flash[:alert]).to be_present
  end

  it "refuses to delete a group with members" do
    create(:feature_group_topic, feature_group: group)
    delete admin_feature_group_path(group)
    expect(FeatureGroup.exists?(group.id)).to be(true)
  end

  it "deletes an empty group" do
    delete admin_feature_group_path(group)
    expect(FeatureGroup.exists?(group.id)).to be(false)
  end

  it "refuses to delete a merged group" do
    group.merge_into!(other)
    get admin_feature_group_path(group)
    expect(response.body).not_to include(">Delete<")
    delete admin_feature_group_path(group)
    expect(FeatureGroup.exists?(group.id)).to be(true)
    expect(flash[:alert]).to be_present
  end

  it "dissolves a group keeping human members" do
    seed, llm, human = create_list(:topic, 3)
    create(:feature_group_topic, feature_group: group, topic: seed, source: "seed")
    create(:feature_group_topic, feature_group: group, topic: llm, source: "llm")
    create(:feature_group_topic, feature_group: group, topic: human, source: "human")
    get admin_feature_group_path(group)
    expect(response.body).to include("Dissolve", "Release to bot")

    post dissolve_admin_feature_group_path(group)

    expect(FeatureGroupTopic.where(feature_group_id: group.id).pluck(:topic_id)).to eq([ human.id ])
    expect(FeatureGroupTopic.where(topic_id: [ seed.id, llm.id ])).to be_empty
  end

  it "deletes a group left empty by dissolve" do
    create(:feature_group_topic, feature_group: group, topic: topic, source: "seed")
    post dissolve_admin_feature_group_path(group)
    delete admin_feature_group_path(group)
    expect(FeatureGroup.exists?(group.id)).to be(false)
  end

  it "releases a thread to the bot" do
    create(:feature_group_topic, feature_group: group, topic: topic, source: "human")
    delete release_admin_feature_group_membership_path(topic.id)
    expect(FeatureGroupTopic.where(topic_id: topic.id)).to be_empty
    expect(flash[:notice]).to be_present
  end

  it "moves and removes a thread as human" do
    patch admin_feature_group_membership_path(topic.id), params: { feature_group_id: other.id }
    expect(topic.reload.feature_group_topic).to have_attributes(feature_group_id: other.id, source: "human")
    patch admin_feature_group_membership_path(topic.id), params: { feature_group_id: "" }
    expect(topic.reload.feature_group_topic).to have_attributes(feature_group_id: nil, source: "human")
  end

  it "accepts a slug and follows merges" do
    other.merge_into!(group)
    patch admin_feature_group_membership_path(topic.id), params: { feature_group_id: other.slug }
    expect(topic.reload.feature_group_topic.feature_group_id).to eq(group.id)
  end

  it "rejects unknown group" do
    patch admin_feature_group_membership_path(topic.id), params: { feature_group_id: "nope" }
    expect(topic.reload.feature_group_topic).to be_nil
    expect(flash[:alert]).to be_present
  end

  it "keeps membership controls off the thread page" do
    create(:feature_group_topic, feature_group: group, topic: topic, source: "seed")
    get topic_path(topic)
    expect(response.body).not_to include(admin_feature_group_membership_path(topic.id), "Group id or slug")
  end

  it "asks before removing or releasing a thread on the group page" do
    create(:feature_group_topic, feature_group: group, topic: topic, source: "seed")
    get admin_feature_group_path(group)
    page = Nokogiri::HTML(response.body)
    remove = page.at_css("form[action='#{admin_feature_group_membership_path(topic.id)}'][method='post'] input[name='_method'][value='delete']")
    release = page.at_css("form[action='#{release_admin_feature_group_membership_path(topic.id)}']")
    expect(remove.ancestors("form").first["data-turbo-confirm"]).to be_present
    expect(release["data-turbo-confirm"]).to be_present
  end

  it "moves a thread from the group page" do
    create(:feature_group_topic, feature_group: group, topic: topic, source: "seed")
    get admin_feature_group_path(group)
    expect(response.body).to include("Move to")
    patch admin_feature_group_membership_path(topic.id), params: { feature_group_id: other.slug }
    expect(topic.reload.feature_group_topic).to have_attributes(feature_group_id: other.id, source: "human")
  end

  it "adds a thread by id from the group page" do
    get admin_feature_group_path(group)
    expect(response.body).to include(admin_feature_group_memberships_path)
    post admin_feature_group_memberships_path, params: { topic_id: topic.id, feature_group_id: group.id }
    expect(topic.reload.feature_group_topic).to have_attributes(feature_group_id: group.id, source: "human")
  end

  it "deletes membership as human no-group" do
    create(:feature_group_topic, feature_group: group, topic: topic)
    delete admin_feature_group_membership_path(topic.id)
    expect(topic.reload.feature_group_topic).to have_attributes(feature_group_id: nil, source: "human")
  end

  it "shows versions with the override form" do
    commit = create(:commit)
    create(:feature_group_version, feature_group: group, major: 19, status: "in-development", details: { "commit_ids" => [ commit.id ] })
    create(:feature_group_version, feature_group: group, major: 20, status: "worked-on", source: "human")
    get admin_feature_group_path(group)
    expect(response.body).to include("in-development", "worked-on", commit.sha[0, 10], "Clear", "Override")
  end

  it "preselects the current status and role in the version override form" do
    create(:feature_group_version, feature_group: group, major: 19, status: "shipped", role: "improved")
    get admin_feature_group_path(group)
    doc = Nokogiri::HTML(response.body)
    form = doc.css("form").find { |f| f.at_css("input[name=major][value='19']") }
    expect(form.at_css("select[name=status] option[selected]")["value"]).to eq("shipped")
    expect(form.at_css("select[name=role] option[selected]")["value"]).to eq("improved")
  end

  it "overrides a version as human" do
    create(:feature_group_version, feature_group: group, major: 19, status: "in-development")
    post override_version_admin_feature_group_path(group), params: { major: 19, status: "reverted" }
    expect(group.feature_group_versions.pluck(:major, :status, :source)).to eq([ [ 19, "reverted", "human" ] ])
  end

  it "stores the role on override" do
    post override_version_admin_feature_group_path(group), params: { major: 19, status: "shipped", role: "improved" }
    expect(group.feature_group_versions.pluck(:role, :source)).to eq([ [ "improved", "human" ] ])
  end

  it "rejects an unknown role" do
    post override_version_admin_feature_group_path(group), params: { major: 19, status: "shipped", role: "nope" }
    expect(group.feature_group_versions).to be_empty
  end

  it "rejects an unknown version status" do
    post override_version_admin_feature_group_path(group), params: { major: 19, status: "nope" }
    expect(group.feature_group_versions).to be_empty
    expect(flash[:alert]).to be_present
  end

  it "clears an override and recomputes" do
    create(:feature_group_topic, feature_group: group, topic: topic)
    Classify::BotNote.new(topic).write!(%w[feature major])
    create(:commit_topic, topic: topic, commit: create(:commit, branches: %w[REL_19_STABLE master]))
    create(:feature_group_version, feature_group: group, major: 19, status: "reverted", source: "human")

    delete clear_version_admin_feature_group_path(group), params: { major: 19 }

    expect(group.feature_group_versions.pluck(:major, :status, :source)).to eq([ [ 19, "in-development", "computed" ] ])
  end

  describe "version refresh" do
    def feature_thread
      create(:topic).tap do |t|
        Classify::BotNote.new(t).write!(%w[feature major])
        create(:commit_topic, topic: t, commit: create(:commit, branches: %w[REL_19_STABLE master]))
      end
    end

    def majors(g) = g.feature_group_versions.where(source: "computed").pluck(:major)

    let(:member) { feature_thread }

    before do
      create(:feature_group_topic, feature_group: group, topic: member)
      FeatureGroups::Versions.refresh!([ group.id ])
    end

    it "moves a thread and refreshes both groups" do
      patch admin_feature_group_membership_path(member.id), params: { feature_group_id: other.id }
      expect(majors(group)).to be_empty
      expect(majors(other)).to eq([ 19 ])
    end

    it "removes a thread and refreshes its group" do
      delete admin_feature_group_membership_path(member.id)
      expect(majors(group)).to be_empty
    end

    it "releases a thread and refreshes its group" do
      delete release_admin_feature_group_membership_path(member.id)
      expect(majors(group)).to be_empty
    end

    it "dissolves and refreshes the group" do
      post dissolve_admin_feature_group_path(group)
      expect(majors(group)).to be_empty
    end

    it "merges and refreshes both groups" do
      post merge_admin_feature_group_path(group), params: { target_id: other.id }
      expect(majors(group)).to be_empty
      expect(majors(other)).to eq([ 19 ])
    end

    it "recomputes on demand" do
      FeatureGroupVersion.delete_all
      get admin_feature_group_path(group)
      expect(response.body).to include("Recompute versions")
      post recompute_versions_admin_feature_group_path(group)
      expect(majors(group)).to eq([ 19 ])
    end
  end

  describe "duplicates" do
    let!(:a) { create(:feature_group, name: "OAuth authentication") }
    let!(:b) { create(:feature_group, name: "OAuth authentication support") }

    it "lists pairs with merge buttons" do
      get duplicates_admin_feature_groups_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("OAuth authentication support", merge_admin_feature_group_path(a), merge_admin_feature_group_path(b))
    end

    it "refuses non-admins" do
      sign_in_as(create(:user))
      get duplicates_admin_feature_groups_path
      expect(response).to redirect_to(root_path)
    end

    it "dismisses a pair" do
      post dismiss_pair_admin_feature_groups_path, params: { a_id: b.id, b_id: a.id }
      expect(response).to redirect_to(duplicates_admin_feature_groups_path)
      expect(FeatureGroupDismissedPair.where(low_id: a.id, high_id: b.id)).to exist
      get duplicates_admin_feature_groups_path
      expect(response.body).not_to include("OAuth authentication support")
    end

    it "deleting a dismissed group removes the pair" do
      FeatureGroupDismissedPair.create!(low_id: a.id, high_id: b.id)
      delete admin_feature_group_path(a)
      expect(response).to redirect_to(admin_feature_groups_path)
      expect(FeatureGroupDismissedPair.count).to eq(0)
    end

    it "dismiss is idempotent" do
      2.times { post dismiss_pair_admin_feature_groups_path, params: { a_id: a.id, b_id: b.id } }
      expect(FeatureGroupDismissedPair.count).to eq(1)
    end
  end
end
