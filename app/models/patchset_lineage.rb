class PatchsetLineage < ApplicationRecord
  STEP_KINDS = %w[resend rebase minor_revision major_rework remainder fix_on_top new_series].freeze

  belongs_to :patchset_run
  belongs_to :topic
  belongs_to :message
  belongs_to :parent_message, class_name: "Message", optional: true

  validates :step_kind, inclusion: { in: STEP_KINDS }
  validates :confidence, numericality: { in: 0.0..1.0 }
end
