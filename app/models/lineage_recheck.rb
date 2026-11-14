class LineageRecheck < ApplicationRecord
  belongs_to :topic
  belongs_to :commit
  belongs_to :requested_by_run, class_name: "PatchsetRun", optional: true

  scope :open, -> { where(done_at: nil) }
end
