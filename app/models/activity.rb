class Activity < ApplicationRecord
  belongs_to :user
  belongs_to :subject, polymorphic: true

  TYPES = %w[topic_message_received note_created note_mentioned].freeze

  scope :visible, -> { where(hidden: false) }
  scope :unread, -> { visible.where(read_at: nil) }

  def mark_read!
    update!(read_at: Time.current)
  end

  def self.mark_all_as_read!
    self.where(read_at: nil).update_all(read_at: Time.current)
  end
end
