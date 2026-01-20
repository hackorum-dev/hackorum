# frozen_string_literal: true

class TopicMerge < ApplicationRecord
  belongs_to :source_topic, class_name: "Topic"
  belongs_to :target_topic, class_name: "Topic"
  belongs_to :merged_by, class_name: "User", optional: true

  has_many :message_moves, dependent: :destroy

  validates :source_topic_id, uniqueness: { message: "has already been merged" }
  validate :cannot_merge_into_self
  validate :source_not_already_merged
  validate :target_not_merged

  private

  def cannot_merge_into_self
    return unless source_topic_id == target_topic_id

    errors.add(:target_topic, "cannot be the same as source topic")
  end

  def source_not_already_merged
    return unless source_topic&.merged?

    errors.add(:source_topic, "has already been merged")
  end

  def target_not_merged
    return unless target_topic&.merged?

    errors.add(:target_topic, "has been merged into another topic")
  end
end
