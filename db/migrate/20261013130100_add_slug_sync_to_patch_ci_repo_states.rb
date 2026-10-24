class AddSlugSyncToPatchCiRepoStates < ActiveRecord::Migration[8.0]
  def change
    add_column :patch_ci_repo_states, :slug_sync_digest, :string
    add_column :patch_ci_repo_states, :slug_sync_pushed_at, :datetime
  end
end
