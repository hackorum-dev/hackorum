class FeatureGroupDismissedPair < ApplicationRecord
  belongs_to :low, class_name: "FeatureGroup"
  belongs_to :high, class_name: "FeatureGroup"

  validates :low_id, comparison: { less_than: :high_id }
end
