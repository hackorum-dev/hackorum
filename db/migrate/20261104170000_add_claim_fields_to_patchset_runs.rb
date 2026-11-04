class AddClaimFieldsToPatchsetRuns < ActiveRecord::Migration[8.0]
  def change
    add_column :patchset_runs, :mode, :string
    add_column :patchset_runs, :worker, :string
    add_column :patchset_runs, :claimed_at, :datetime
    add_column :patchset_runs, :bundle_index, :jsonb
    add_index :patchset_runs, [ :status, :claimed_at ]
  end
end
