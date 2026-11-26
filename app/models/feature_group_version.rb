class FeatureGroupVersion < ApplicationRecord
  STATUSES = %w[shipped in-development reverted worked-on].freeze
  ROLES = %w[new improved].freeze
  SOURCES = %w[computed human].freeze

  belongs_to :feature_group

  validates :major, numericality: { only_integer: true, greater_than: 0 }
  validates :status, inclusion: { in: STATUSES }
  validates :role, inclusion: { in: ROLES }, allow_nil: true
  validates :source, inclusion: { in: SOURCES }

  def human?
    source == "human"
  end

  def commit_ids
    Array(details&.dig("commit_ids"))
  end

  def topic_ids
    Array(details&.dig("topic_ids"))
  end
end
