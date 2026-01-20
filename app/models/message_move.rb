# frozen_string_literal: true

class MessageMove < ApplicationRecord
  belongs_to :topic_merge
  belongs_to :message

  validates :message_id, uniqueness: { scope: :topic_merge_id }

  delegate :source_topic, :target_topic, to: :topic_merge
end
