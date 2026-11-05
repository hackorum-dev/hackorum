class TeamFeature < ApplicationRecord
  belongs_to :team
  validates :feature, presence: true,
    inclusion: { in: Feature::NAMES, message: "is not a known feature" }
  validates :feature, uniqueness: { scope: :team_id }
end
