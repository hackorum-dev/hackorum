# frozen_string_literal: true

class TopicMergeService
  class Error < StandardError; end

  Result = Struct.new(:success?, :topic_merge, :error, keyword_init: true)

  def initialize(source_topic:, target_topic:, merged_by:, merge_reason: nil)
    @source_topic = source_topic
    @target_topic = target_topic
    @merged_by = merged_by
    @merge_reason = merge_reason
  end

  def call
    validate!

    ActiveRecord::Base.transaction do
      topic_merge = create_audit_record!
      record_message_moves!(topic_merge)
      move_messages!
      move_notes!
      merge_stars!
      merge_awareness!
      merge_read_ranges!
      move_commitfest_links!
      mark_source_merged!
      recalculate_target_stats!

      Result.new(success?: true, topic_merge: topic_merge)
    end
  rescue Error => e
    Result.new(success?: false, error: e.message)
  rescue ActiveRecord::RecordInvalid => e
    Result.new(success?: false, error: e.record.errors.full_messages.join(", "))
  end

  def preview
    {
      source: topic_summary(source_topic),
      target: topic_summary(target_topic),
      result: merged_preview
    }
  end

  private

  attr_reader :source_topic, :target_topic, :merged_by, :merge_reason

  def validate!
    raise Error, "Source topic not found" unless source_topic
    raise Error, "Target topic not found" unless target_topic
    raise Error, "Cannot merge topic into itself" if source_topic.id == target_topic.id
    raise Error, "Source topic has already been merged" if source_topic.merged?
    raise Error, "Target topic has been merged into another topic" if target_topic.merged?
    raise Error, "User must be an admin" unless merged_by&.admin?
  end

  def create_audit_record!
    TopicMerge.create!(
      source_topic: source_topic,
      target_topic: target_topic,
      merged_by: merged_by,
      merge_reason: merge_reason
    )
  end

  def record_message_moves!(topic_merge)
    source_topic.messages.find_each do |message|
      MessageMove.create!(topic_merge: topic_merge, message: message)
    end
  end

  def move_messages!
    Message.where(topic_id: source_topic.id).update_all(topic_id: target_topic.id)
  end

  def move_notes!
    Note.where(topic_id: source_topic.id).update_all(topic_id: target_topic.id)
  end

  def merge_stars!
    existing_star_user_ids = TopicStar.where(topic: target_topic).pluck(:user_id).to_set

    TopicStar.where(topic: source_topic).find_each do |star|
      if existing_star_user_ids.include?(star.user_id)
        star.destroy!
      else
        star.update!(topic: target_topic)
      end
    end
  end

  def merge_awareness!
    source_awareness = ThreadAwareness.where(topic: source_topic).index_by(&:user_id)
    target_awareness = ThreadAwareness.where(topic: target_topic).index_by(&:user_id)

    source_awareness.each do |user_id, source_record|
      target_record = target_awareness[user_id]

      if target_record
        # Keep the higher awareness level
        if source_record.aware_until_message_id > target_record.aware_until_message_id
          target_record.update!(
            aware_until_message_id: source_record.aware_until_message_id,
            aware_at: [ source_record.aware_at, target_record.aware_at ].max
          )
        end
        source_record.destroy!
      else
        source_record.update!(topic: target_topic)
      end
    end
  end

  def merge_read_ranges!
    source_ranges = MessageReadRange.where(topic: source_topic)

    source_ranges.find_each do |range|
      MessageReadRange.add_range(
        user: User.find(range.user_id),
        topic: target_topic,
        start_id: range.range_start_message_id,
        end_id: range.range_end_message_id
      )
      range.destroy!
    end
  end

  def move_commitfest_links!
    existing_patch_ids = CommitfestPatchTopic.where(topic: target_topic).pluck(:commitfest_patch_id).to_set

    CommitfestPatchTopic.where(topic: source_topic).find_each do |link|
      if existing_patch_ids.include?(link.commitfest_patch_id)
        link.destroy!
      else
        link.update!(topic: target_topic)
      end
    end
  end

  def mark_source_merged!
    source_topic.update!(merged_into_topic: target_topic)
  end

  def recalculate_target_stats!
    target_topic.recalculate_participants!
  end

  def topic_summary(topic)
    messages = topic.messages
    participants = topic.topic_participants.includes(person: :default_alias)

    {
      id: topic.id,
      title: topic.title,
      message_count: topic.message_count,
      participant_count: topic.participant_count,
      first_message_at: messages.minimum(:created_at),
      last_message_at: topic.last_message_at,
      participants: participants.order(message_count: :desc).limit(5).map do |tp|
        {
          name: tp.person&.default_alias&.name,
          message_count: tp.message_count
        }
      end
    }
  end

  def merged_preview
    source_msgs = source_topic.messages
    target_msgs = target_topic.messages

    all_first = [ source_msgs.minimum(:created_at), target_msgs.minimum(:created_at) ].compact.min
    all_last = [ source_topic.last_message_at, target_topic.last_message_at ].compact.max

    source_participants = source_topic.topic_participants.pluck(:person_id).to_set
    target_participants = target_topic.topic_participants.pluck(:person_id).to_set
    combined_participants = source_participants | target_participants

    # Find cross-topic replies (messages in source that reply to messages in target or vice versa)
    source_msg_ids = source_topic.message_ids.to_set
    target_msg_ids = target_topic.message_ids.to_set

    cross_topic_replies = source_msgs.where(reply_to_id: target_msg_ids).count +
                          target_msgs.where(reply_to_id: source_msg_ids).count

    {
      total_message_count: source_topic.message_count + target_topic.message_count,
      total_participant_count: combined_participants.size,
      first_message_at: all_first,
      last_message_at: all_last,
      cross_topic_replies: cross_topic_replies,
      notes_to_move: source_topic.notes.count
    }
  end
end
