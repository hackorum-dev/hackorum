class ClassificationRun < ApplicationRecord
  STATUSES = %w[claimed done failed timeout].freeze
  PHASES = %w[new recheck backfill].freeze
  CLAIM_TTL = 1.hour

  belongs_to :topic
  belongs_to :feature_group, optional: true
  belongs_to :through_message, class_name: "Message", optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :phase, inclusion: { in: PHASES }, allow_nil: true

  scope :done, -> { where(status: "done") }
  scope :claimed, -> { where(status: "claimed") }
  scope :stale_claims, -> { claimed.where(claimed_at: ...CLAIM_TTL.ago) }

  # newest run of each topic, any status
  def self.latest_for(topic_ids)
    select("DISTINCT ON (classification_runs.topic_id) classification_runs.*")
      .where(topic_id: topic_ids)
      .order("classification_runs.topic_id, classification_runs.created_at DESC, classification_runs.id DESC")
  end

  def finish!(status:, **attrs)
    now = Time.current
    duration = attrs[:duration_s] || (started_at && now - started_at)
    update!(attrs.merge(status: status, finished_at: now, duration_s: duration))
  end
end
