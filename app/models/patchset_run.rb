class PatchsetRun < ApplicationRecord
  STATUSES = %w[queued claimed running done failed timeout].freeze
  MODES = %w[trailer full lineage].freeze
  CLAIM_TTL = 1.hour

  belongs_to :topic
  belongs_to :through_message, class_name: "Message", optional: true
  has_many :lineages, class_name: "PatchsetLineage", dependent: :delete_all
  has_many :verdicts, class_name: "CommitVerdict", dependent: :delete_all

  validates :status, inclusion: { in: STATUSES }
  validates :mode, inclusion: { in: MODES }, allow_nil: true

  scope :done, -> { where(status: "done") }
  scope :claimed, -> { where(status: "claimed") }
  scope :blocking, -> { where.not(status: "queued") }
  scope :stale_claims, -> { claimed.where(claimed_at: ...CLAIM_TTL.ago) }
  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  def self.current_for(topic_id)
    done.where(topic_id: topic_id).newest_first.first
  end

  def finish!(status:, **attrs)
    now = Time.current
    duration = attrs[:duration_s] || (started_at && now - started_at)
    update!(attrs.merge(status: status, finished_at: now, duration_s: duration))
  end
end
