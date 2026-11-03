class AddExtraToCommitVerdicts < ActiveRecord::Migration[8.0]
  def change
    add_column :commit_verdicts, :extra, :boolean, null: false, default: false
  end
end
