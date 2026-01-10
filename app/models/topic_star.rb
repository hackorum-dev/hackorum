class TopicStar < ApplicationRecord
  belongs_to :user
  belongs_to :topic

  validates :user_id, uniqueness: { scope: :topic_id }

  def self.toggle_star(user:, topic:)
    existing = find_by(user: user, topic: topic)
    if existing
      existing.destroy
      false
    else
      create!(user: user, topic: topic)
      true
    end
  end

  def self.starred_by_user?(user:, topic:)
    exists?(user: user, topic: topic)
  end
end
