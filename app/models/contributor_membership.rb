class ContributorMembership < ApplicationRecord
  belongs_to :person, optional: true

  enum :contributor_type, {
    core_team: "core_team",
    committer: "committer",
    major_contributor: "major_contributor",
    significant_contributor: "significant_contributor",
    past_major_contributor: "past_major_contributor",
    past_significant_contributor: "past_significant_contributor"
  }
end
