# frozen_string_literal: true

class Admin::FeatureGroupMembershipsController < Admin::BaseController
  before_action :set_topic

  def active_admin_section
    :feature_groups
  end

  def create
    update
  end

  def update
    ref = params[:feature_group_id].to_s.strip
    group = nil
    if ref.present?
      group = FeatureGroup.find_by(slug: ref) || (FeatureGroup.find_by(id: ref) if ref.match?(/\A\d+\z/))
      return back_with(alert: "Group not found") unless group
      group = group.surviving
    end
    write(group)
    back_with(notice: "Feature group updated")
  end

  def destroy
    write(nil)
    back_with(notice: "Thread removed from group")
  end

  # no row at all: the bot may assign it again
  def release
    membership = FeatureGroupTopic.find_by(topic_id: @topic.id)
    if membership
      membership.destroy!
      FeatureGroups::Versions.refresh_isolated!([ membership.feature_group_id ].compact)
    end
    back_with(notice: "Thread released to the bot")
  end

  private

  def write(group)
    membership = FeatureGroupTopic.find_or_initialize_by(topic_id: @topic.id)
    old_id = membership.feature_group_id
    membership.update!(feature_group: group, source: "human")
    FeatureGroups::Versions.refresh_isolated!([ old_id, group&.id ].compact)
  end

  def back_with(flash_opts)
    redirect_back_or_to topic_path(@topic), **flash_opts
  end

  def set_topic
    @topic = Topic.find_by(id: params[:topic_id].to_s.strip)
    redirect_back_or_to admin_feature_groups_path, alert: "Thread not found" unless @topic
  end
end
