class SavedSearch < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :team, optional: true
  has_many :saved_search_preferences, dependent: :destroy

  enum :scope, { global: "global", user: "user", team: "team" }, prefix: true

  validates :name, presence: true
  validates :query, presence: true
  validates :name, uniqueness: { scope: [:scope, :user_id, :team_id] }
  validate :single_owner

  scope :global_searches, -> { scope_global }
  scope :user_templates, -> { scope_user.where(user_id: nil) }
  scope :team_templates, -> { scope_team.where(team_id: nil) }
  scope :for_user, ->(user) { scope_user.where(user_id: user.id) }
  scope :for_team, ->(team) { scope_team.where(team_id: team.id) }

  def system_defined?
    (scope_user? && user_id.nil?) || (scope_team? && team_id.nil?)
  end

  def resolve_query(team: nil)
    return query unless team

    query.gsub("{{team_name}}", team.name)
  end

  def self.visible_to(user)
    return scope_global if user.nil?

    team_ids = user.team_ids

    where(
      "scope = 'global' OR " \
      "(scope = 'user' AND (user_id = :user_id OR user_id IS NULL)) OR " \
      "(scope = 'team' AND (team_id IN (:team_ids) OR team_id IS NULL))",
      user_id: user.id,
      team_ids: team_ids.presence || [nil]
    )
  end

  def self.visible_to_unhidden(user)
    hidden_ids = SavedSearchPreference.where(user: user, hidden: true).select(:saved_search_id)
    visible_to(user).where.not(id: hidden_ids)
  end

  private

  def single_owner
    if user_id.present? && team_id.present?
      errors.add(:base, "cannot have both user and team")
    end
  end
end
