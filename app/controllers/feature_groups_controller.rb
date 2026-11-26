class FeatureGroupsController < ApplicationController
  def index
    counts = FeatureGroupTopic.joins(:topic).merge(Topic.active)
                              .group(:feature_group_id).pluck(:feature_group_id, Arel.sql("COUNT(*)"), Arel.sql("MAX(topics.last_message_at)"))
    stats = counts.to_h { |id, n, at| [ id, { count: n, latest: at } ] }
    @groups = FeatureGroup.live.where(id: stats.keys).order(:name).to_a
    @stats = stats
  end

  def show
    group = FeatureGroup.find_by(slug: params[:slug])
    return render_not_found unless group
    return redirect_to(feature_group_path(group.surviving.slug), status: :moved_permanently) if group.merged_into_id

    @group = group
    @versions = group.feature_group_versions.order(major: :desc)
    @topics = group.topics.active.order(Arel.sql("topics.last_message_at DESC NULLS LAST"), id: :desc).to_a
    @version_topics = Topic.active.where(id: @versions.flat_map(&:topic_ids)).index_by(&:id)
    @tags = Classify::BotNote.tags_by_topic((@topics.map(&:id) + @version_topics.keys).uniq)
  end

  private

  def render_not_found
    render file: Rails.public_path.join("404.html"), status: :not_found, layout: false
  end
end
