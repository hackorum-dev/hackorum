class User < ApplicationRecord
  has_secure_password validations: false

  belongs_to :person
  has_many :aliases
  has_many :topics, through: :aliases
  has_many :messages, through: :aliases
  has_many :identities
  has_many :team_members
  has_many :teams, through: :team_members
  has_many :notes, foreign_key: :author_id
  has_many :note_edits, foreign_key: :editor_id
  has_many :activities
  has_many :topic_stars, dependent: :destroy
  has_many :starred_topics, through: :topic_stars, source: :topic
  has_many :saved_searches
  has_many :saved_search_preferences

  enum :mention_restriction, { anyone: "anyone", teammates_only: "teammates_only" }, default: :anyone

  scope :active, -> { where(deleted_at: nil) }

  def primary_alias
    person&.default_alias
  end

  def mentionable_by?(mentioner)
    return false unless mentioner
    return true if anyone?
    shares_team_with?(mentioner)
  end

  def shares_team_with?(other_user)
    return false unless other_user
    team_ids.intersect?(other_user.team_ids)
  end

  attr_accessor :skip_name_reservation

  validates :username, format: { with: /\A[a-zA-Z0-9_\-\.]+\z/, allow_blank: true }
  validates :username, uniqueness: { allow_blank: true, case_sensitive: false }
  validates :username, presence: true, on: :registration
  validate :username_available_in_reservations

  before_save :release_old_username_reservation
  after_save :reserve_username
  after_destroy :release_name_reservation

  private

  def username_available_in_reservations
    return if username.blank? || !will_save_change_to_username? || skip_name_reservation

    normalized = NameReservation.normalize(username)
    existing = NameReservation.find_by(name: normalized)
    return unless existing
    return if existing.owner_type == "User" && existing.owner_id == id

    errors.add(:username, "is already taken")
  end

  def release_old_username_reservation
    return unless will_save_change_to_username?
    NameReservation.release_for(self) if username_was.present?
  end

  def reserve_username
    return if username.blank? || skip_name_reservation
    NameReservation.reserve!(name: username, owner: self)
  end

  def release_name_reservation
    NameReservation.release_for(self)
  end
end
