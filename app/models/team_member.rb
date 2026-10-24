# frozen_string_literal: true

class TeamMember < ApplicationRecord
  enum :role, {
    member: "member",
    admin: "admin"
  }, prefix: true, validate: true

  belongs_to :team
  belongs_to :user

  validates :role, presence: true
  validates :user_id, uniqueness: { scope: :team_id }

  def self.add_member(team:, user:, role: :member)
    create!(team:, user:, role:)
  end

  # Convenience helpers without enum prefix for ergonomics
  def admin?
    role_admin?
  end

  def member?
    role_member?
  end
end
