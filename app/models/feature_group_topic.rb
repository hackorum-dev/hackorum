class FeatureGroupTopic < ApplicationRecord
  belongs_to :feature_group, optional: true
  belongs_to :topic

  validates :source, inclusion: { in: FeatureGroup::SOURCES }

  def human?
    source == "human"
  end
end
