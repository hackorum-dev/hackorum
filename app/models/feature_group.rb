class FeatureGroup < ApplicationRecord
  SOURCES = %w[seed llm human].freeze

  belongs_to :merged_into, class_name: "FeatureGroup", optional: true
  has_many :feature_group_topics
  has_many :topics, through: :feature_group_topics
  has_many :feature_group_versions, dependent: :delete_all

  validates :name, presence: true
  validates :slug, presence: true
  validates :source, inclusion: { in: SOURCES }

  before_validation :assign_slug, on: :create

  scope :live, -> { where(merged_into_id: nil) }

  def self.normalize_name(str)
    str.to_s.strip.gsub(/\s+/, " ").downcase
  end

  # merged groups match too, so a merged-away name is not recreated
  def self.find_by_normalized_name(str)
    target = normalize_name(str)
    where("lower(regexp_replace(btrim(name), '\\s+', ' ', 'g')) = ?", target)
      .order(Arel.sql("merged_into_id IS NOT NULL"), :id).first&.surviving
  end

  def surviving
    group = self
    seen = Set.new
    while group.merged_into_id && seen.add?(group.id)
      group = group.merged_into
    end
    group
  end

  def merge_into!(other)
    other = other.surviving
    raise ArgumentError, "cannot merge into itself" if other.id == id

    transaction do
      FeatureGroupTopic.where(feature_group_id: id).update_all(feature_group_id: other.id)
      FeatureGroup.where(merged_into_id: id).update_all(merged_into_id: other.id)
      update!(merged_into: other)
    end
  end

  private

  def assign_slug
    return if slug.present? || name.blank?

    base = name.parameterize
    base = "group" if base.blank?
    candidate = base
    n = 1
    candidate = "#{base}-#{n += 1}" while FeatureGroup.exists?(slug: candidate)
    self.slug = candidate
  end
end
