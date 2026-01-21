# frozen_string_literal: true

class MessageActivityBuilder
  def initialize(message)
    @message = message
  end

  def process!
    ActiveRecord::Base.transaction do
      auto_star_topic_for_sender
      mark_message_read_for_sender
      fan_out_to_starring_users
    end
  end

  private

  def auto_star_topic_for_sender
    sender_user = @message.sender.user
    return unless sender_user

    TopicStar.find_or_create_by(user: sender_user, topic: @message.topic)
  rescue ActiveRecord::RecordNotUnique
    # Race condition - another process already created the star
  end

  def mark_message_read_for_sender
    sender_user = @message.sender.user
    return unless sender_user

    MessageReadRange.add_range(
      user: sender_user,
      topic: @message.topic,
      start_id: @message.id,
      end_id: @message.id
    )

    ThreadAwareness.mark_until(
      user: sender_user,
      topic: @message.topic,
      until_message_id: @message.id
    )
  end

  def fan_out_to_starring_users
    starring_user_ids = @message.topic.topic_stars.pluck(:user_id)
    return if starring_user_ids.empty?

    sender_user_id = @message.sender.user_id
    payload = build_payload

    starring_user_ids.each do |user_id|
      next if user_id == sender_user_id

      Activity.create!(
        user_id: user_id,
        activity_type: "topic_message_received",
        subject: @message,
        payload: payload,
        read_at: nil,
        hidden: false
      )
    end
  end

  def build_payload
    {
      topic_id: @message.topic_id,
      message_id: @message.id
    }
  end
end
