# frozen_string_literal: true

class Team < ApplicationRecord
  has_many :team_members, dependent: :destroy
  has_many :users, through: :team_members
  has_many :saved_searches

  # Visibility levels:
  # - private: only members can see/access the team, only members can mention
  # - visible: anyone can see/access the team, only members can mention
  # - open: anyone can see/access the team, anyone can mention
  enum :visibility, { private: "private", visible: "visible", open: "open" }, default: :private, prefix: true

  validates :name, presence: true
  validates :name, format: { with: /\A[a-zA-Z0-9_\-\.]+\z/ }
  validate :name_available_in_reservations

  after_create :reserve_name
  after_destroy :release_name_reservation

  def member?(user)
    return false unless user
    team_members.exists?(user_id: user.id)
  end

  def admin?(user)
    return false unless user
    team_members.role_admin.exists?(user_id: user.id)
  end

  def last_admin?(team_member)
    return false unless team_member.admin?
    team_members.role_admin.count == 1
  end

  def accessible_to?(user)
    return true if visibility_visible? || visibility_open?
    member?(user)
  end

  def mentionable_by?(user)
    return true if visibility_open?
    member?(user)
  end

  private

  def name_available_in_reservations
    return if name.blank? || !will_save_change_to_name?

    normalized = NameReservation.normalize(name)
    existing = NameReservation.find_by(name: normalized)
    return unless existing
    return if existing.owner_type == "Team" && existing.owner_id == id

    errors.add(:name, "is already taken")
  end

  def reserve_name
    NameReservation.reserve!(name:, owner: self)
  end

  def release_name_reservation
    NameReservation.release_for(self)
  end
end
