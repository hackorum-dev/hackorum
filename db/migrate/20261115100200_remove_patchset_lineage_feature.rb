class RemovePatchsetLineageFeature < ActiveRecord::Migration[8.0]
  def up
    execute "DELETE FROM user_features WHERE feature = 'patchset_lineage'"
    execute "DELETE FROM team_features WHERE feature = 'patchset_lineage'"
  end

  def down
  end
end
