class CommitVerdict < ApplicationRecord
  VERDICTS = %w[as_is modified partial from_discussion other_thread not_this_thread undecided].freeze
  COMMITTED = %w[as_is modified partial from_discussion].freeze
  ORIGINS = %w[trailer overlap manual previous extra].freeze
  CHANGE_LEVELS = %w[light moderate significant].freeze
  COVERAGES = %w[final earlier none].freeze

  belongs_to :patchset_run
  belongs_to :topic
  belongs_to :commit
  belongs_to :source_message, class_name: "Message", optional: true
  belongs_to :author_message, class_name: "Message", optional: true

  validates :verdict, inclusion: { in: VERDICTS }
  validates :origin, inclusion: { in: ORIGINS }
  validates :change_level, inclusion: { in: CHANGE_LEVELS }, allow_nil: true
  validates :confidence, numericality: { in: 0.0..1.0 }

  def committed? = COMMITTED.include?(verdict)
end
