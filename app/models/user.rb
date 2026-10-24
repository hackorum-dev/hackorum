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
  has_one :default_saved_search_preference, -> { where(default: true) }, class_name: "SavedSearchPreference"
  has_one :default_saved_search, through: :default_saved_search_preference, source: :saved_search
  has_many :outgoing_drafts, dependent: :destroy
  has_many :user_features, dependent: :destroy

  enum :mention_restriction, { anyone: "anyone", teammates_only: "teammates_only" }, default: :anyone

  UNVERIFIED_TTL = 3.days

  scope :verified, -> { where.not(verified_at: nil) }
  scope :unverified, -> { where(verified_at: nil) }
  scope :active, -> { verified.where(deleted_at: nil) }

  scope :matching, ->(query) {
    like = "%#{ActiveRecord::Base.sanitize_sql_like(query.to_s.strip)}%"
    where(
      "users.username ILIKE :q OR EXISTS (" \
      "SELECT 1 FROM aliases WHERE aliases.person_id = users.person_id " \
      "AND (aliases.email ILIKE :q OR aliases.name ILIKE :q))",
      q: like
    )
  }

  def primary_alias
    person&.default_alias
  end

  def sender_alias_for(email)
    normalized = email.to_s.downcase.strip
    primary    = primary_alias
    if primary && primary.user_id == id && primary.email.to_s.downcase.strip == normalized
      return primary
    end

    aliases.by_email(email)
           .order(Arel.sql("CASE WHEN name = 'Noname' THEN 1 ELSE 0 END"))
           .order(sender_count: :desc)
           .order(:created_at)
           .first
  end

  def can_send_email?
    identities.send_authorized.exists?
  end

  def has_feature?(name)
    admin? || user_features.exists?(feature: name.to_s)
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

  validates :username, format: { with: /\A[a-zA-Z0-9_\-\.]+\z/, allow_blank: true }
  validates :username, uniqueness: { allow_blank: true, case_sensitive: false }
  validates :username, presence: true, on: :registration
  validates :password, presence: true, confirmation: true, on: :registration
  validate :username_available_in_reservations

  before_save :release_old_username_reservation
  after_save :reserve_username
  after_destroy :release_name_reservation

  def verified?
    verified_at.present?
  end

  def self.cleanup_unverified!(older_than: UNVERIFIED_TTL)
    unverified.where(deleted_at: nil).where("created_at < ?", older_than.ago).find_each do |user|
      transaction do
        person = user.person
        UserToken.where(user_id: user.id).delete_all
        user.destroy!
        person.destroy! if person && !person.aliases.exists? && !User.where(person_id: person.id).exists?
      end
    rescue ActiveRecord::InvalidForeignKey => e
      Rails.logger.warn("Unverified user #{user.id} cleanup failed: #{e.message}")
    end
  end

  private

  def username_available_in_reservations
    return if username.blank? || !will_save_change_to_username?

    if NameReservation.reserved?(username)
      errors.add(:username, "is reserved")
      return
    end

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
    return if username.blank?
    NameReservation.reserve!(name: username, owner: self)
  end

  def release_name_reservation
    NameReservation.release_for(self)
  end
end
