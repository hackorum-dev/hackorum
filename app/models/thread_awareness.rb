# frozen_string_literal: true

class ThreadAwareness < ApplicationRecord
  belongs_to :user
  belongs_to :topic

  validates :aware_until_message_id, :aware_at, presence: true

  def self.mark_until(user:, topic:, until_message_id:, aware_at: Time.current)
    transaction do
      record = lock.find_or_initialize_by(user:, topic:)
      record.aware_at = aware_at if record.new_record?
      record.aware_until_message_id = [ record.aware_until_message_id || 0, until_message_id ].max
      record.save!
      record
    end
  end

  def self.covering?(user:, topic:, message_id:)
    where(user:, topic:)
      .where("aware_until_message_id >= ?", message_id)
      .exists?
  end

  def self.max_aware_message_id(user:, topic:)
    where(user:, topic:).maximum(:aware_until_message_id)
  end
end
