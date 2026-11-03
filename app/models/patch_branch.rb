class PatchBranch < ApplicationRecord
  STATUSES = %w[applied failed].freeze
  # empty is terminal like extract: the apply worked and produced nothing, so no
  # later master makes it produce something. Kept out of the retry tiers.
  FAILURE_STAGES = %w[extract base_detection apply error empty].freeze

  belongs_to :topic
  belongs_to :message
  has_many :ci_runs, class_name: "PatchCiRun", dependent: :destroy
  belongs_to :latest_ci_run, class_name: "PatchCiRun", optional: true
  belongs_to :superseded_by, class_name: "PatchBranch", optional: true

  # set by PatchCi::BranchRows; a belongs_to preload cannot skip the run
  # payload without scoping the association for every writer too
  attr_writer :latest_run_summary

  # loud when never attached: nil would mean "no run", and a row that skipped
  # BranchRows would silently render as "no CI result" instead of erroring
  def latest_run_summary
    unless defined?(@latest_run_summary)
      raise "latest_run_summary not attached: load this row through PatchCi::BranchRows"
    end
    @latest_run_summary
  end

  validates :branch_name, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :failure_stage, inclusion: { in: FAILURE_STAGES }, allow_nil: true
  validates :ci_status, inclusion: { in: PatchCiRun::STATUSES }, allow_nil: true

  scope :applied, -> { where(status: "applied") }
  scope :failed, -> { where(status: "failed") }
  scope :pushed, -> { where.not(pushed_at: nil) }
  scope :ci_in_flight, -> { where(ci_status: PatchCiRun::IN_FLIGHT_BRANCH_STATUSES) }
  scope :ci_terminal, -> { where(ci_status: PatchCiRun::TERMINAL_STATUSES) }
  scope :current, -> { where(superseded_by_id: nil, lineage_only: false) }

  def behind_commits(repo_state)
    return nil unless repo_state && base_commit_height
    repo_state.master_commit_height - base_commit_height
  end

  def behind_days(repo_state)
    return nil unless repo_state && base_committed_at
    ((repo_state.master_committed_at - base_committed_at) / 1.day).floor
  end
end
