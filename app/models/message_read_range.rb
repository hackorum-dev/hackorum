# frozen_string_literal: true

class MessageReadRange < ApplicationRecord
  belongs_to :user
  belongs_to :topic

  validates :range_start_message_id, :range_end_message_id, :read_at, presence: true
  validate :range_order

  def self.add_range(user:, topic:, start_id:, end_id:, read_at: Time.current)
    s = [ start_id, end_id ].min
    e = [ start_id, end_id ].max

    transaction do
      overlapping = lock.where(user:, topic:)
                        .where("range_end_message_id >= ? AND range_start_message_id <= ?", s - 1, e + 1)

      if overlapping.exists?
        ranges = overlapping.pluck(:range_start_message_id, :range_end_message_id)
        min_start = ranges.map(&:first).min
        max_end = ranges.map(&:last).max
        s = [ s, min_start ].min
        e = [ e, max_end ].max
        overlapping.delete_all
      end

      count = Message.where(topic_id: topic.id, id: s..e).count

      create!(
        user: user,
        topic: topic,
        range_start_message_id: s,
        range_end_message_id: e,
        message_count: count,
        read_at: read_at
      )
    end
  end

  def self.covering?(user:, topic:, message_id:)
    where(user:, topic:)
      .where("range_start_message_id <= ? AND range_end_message_id >= ?", message_id, message_id)
      .exists?
  end

  def self.max_read_message_id(user:, topic:)
    where(user:, topic:).maximum(:range_end_message_id)
  end

  private

  def range_order
    return if range_start_message_id.blank? || range_end_message_id.blank?
    errors.add(:range_end_message_id, "must be >= start") if range_end_message_id < range_start_message_id
  end
end
