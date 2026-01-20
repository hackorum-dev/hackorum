# frozen_string_literal: true

class Admin::TopicMergesController < Admin::BaseController
  before_action :set_source_topic, only: [ :new, :preview, :create ]
  before_action :set_target_topic, only: [ :preview, :create ]

  def index
    @topic_merges = TopicMerge.includes(:source_topic, :target_topic, :merged_by)
                              .order(created_at: :desc)
                              .limit(100)
  end

  def new
    @suggestions = Topic.suggest_merge_targets(@source_topic)
  end

  def preview
    return redirect_to_new_with_error("Target topic is required") unless @target_topic

    service = TopicMergeService.new(
      source_topic: @source_topic,
      target_topic: @target_topic,
      merged_by: current_user
    )
    @preview = service.preview
  end

  def create
    return redirect_to_new_with_error("Target topic is required") unless @target_topic

    service = TopicMergeService.new(
      source_topic: @source_topic,
      target_topic: @target_topic,
      merged_by: current_user,
      merge_reason: params[:merge_reason]
    )

    result = service.call

    if result.success?
      redirect_to topic_path(@target_topic), notice: "Topics merged successfully. #{@source_topic.message_count} messages moved."
    else
      redirect_to new_admin_topic_merge_path(@source_topic), alert: "Merge failed: #{result.error}"
    end
  end

  private

  def set_source_topic
    @source_topic = Topic.find(params[:topic_id])
  rescue ActiveRecord::RecordNotFound
    redirect_to topics_path, alert: "Source topic not found"
  end

  def set_target_topic
    target_id = params[:target_topic_id].presence
    @target_topic = Topic.find_by(id: target_id) if target_id
  end

  def redirect_to_new_with_error(message)
    redirect_to new_admin_topic_merge_path(@source_topic), alert: message
  end
end
