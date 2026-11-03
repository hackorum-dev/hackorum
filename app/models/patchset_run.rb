class PatchsetRun < ApplicationRecord
  STATUSES = %w[queued running done failed timeout].freeze

  belongs_to :topic
  belongs_to :through_message, class_name: "Message", optional: true
  has_many :lineages, class_name: "PatchsetLineage", dependent: :delete_all
  has_many :verdicts, class_name: "CommitVerdict", dependent: :delete_all

  validates :status, inclusion: { in: STATUSES }

  scope :done, -> { where(status: "done") }
  scope :newest_first, -> { order(created_at: :desc, id: :desc) }

  def self.current_for(topic_id)
    done.where(topic_id: topic_id).newest_first.first
  end

  def finish!(status:, **attrs)
    now = Time.current
    update!(attrs.merge(status: status, finished_at: now,
                        duration_s: started_at ? now - started_at : nil))
  end
end
