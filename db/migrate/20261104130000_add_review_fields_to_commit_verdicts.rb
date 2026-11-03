class AddReviewFieldsToCommitVerdicts < ActiveRecord::Migration[8.0]
  def change
    add_column :commit_verdicts, :origin, :string, null: false, default: "trailer"
    add_column :commit_verdicts, :change_level, :string
    add_column :commit_verdicts, :reviews, :jsonb
    add_column :commit_verdicts, :reviewers_final, :integer
    add_column :commit_verdicts, :reviewers_earlier, :integer
    add_column :commit_verdicts, :reviewers_none, :integer
    add_column :patchset_runs, :failure_kind, :string
  end
end
