class Note < ApplicationRecord
  belongs_to :topic
  belongs_to :message, optional: true
  belongs_to :author, class_name: "User"
  belongs_to :last_editor, class_name: "User", optional: true

  has_many :note_mentions, dependent: :destroy
  has_many :note_tags, dependent: :destroy
  has_many :note_edits, dependent: :destroy
  has_many :activities, as: :subject, dependent: :destroy

  MENTION_PATTERN = /(?:^|[^@\w])@([A-Za-z0-9_.-]*[A-Za-z0-9_-])/
  TAG_PATTERN = /(?:^|[^#\w])#([A-Za-z0-9_.-]*[A-Za-z0-9_-])/
  GLOBAL_MENTION = "global"

  scope :active, -> { where(deleted_at: nil) }
  scope :for_topic, ->(topic) { where(topic:) }
  scope :global_visible, -> { active.where(global: true) }
  scope :visible_to, ->(user) {
    return global_visible unless user

    uid = user.id
    joins(
      sanitize_sql_array([
        <<~SQL.squish, uid, uid
          LEFT JOIN note_mentions nm_user
            ON nm_user.note_id = notes.id
           AND nm_user.mentionable_type = 'User'
           AND nm_user.mentionable_id = ?
          LEFT JOIN note_mentions nm_team
            ON nm_team.note_id = notes.id
           AND nm_team.mentionable_type = 'Team'
          LEFT JOIN team_members tm
            ON tm.team_id = nm_team.mentionable_id
           AND tm.user_id = ?
        SQL
      ])
    ).where(
      sanitize_sql_array([
        "notes.global OR notes.author_id = :uid OR nm_user.id IS NOT NULL OR tm.id IS NOT NULL",
        uid: uid
      ])
    ).where(deleted_at: nil).distinct
  }

  validates :body, presence: true
  validate :message_matches_topic

  def visible_to?(user)
    self.class.visible_to(user).where(id: id).exists?
  end

  def thread_key
    message_id || :thread
  end

  def tag_only?
    body.to_s.gsub(MENTION_PATTERN, "").gsub(TAG_PATTERN, "").strip.empty?
  end

  def editable_by?(user)
    return false unless user
    author_id == user.id || (global? && user.admin?)
  end

  private

  def message_matches_topic
    return unless message
    errors.add(:message, "must belong to the same topic") if message.topic_id != topic_id
  end
end
