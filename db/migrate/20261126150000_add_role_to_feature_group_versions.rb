class AddRoleToFeatureGroupVersions < ActiveRecord::Migration[8.0]
  def change
    add_column :feature_group_versions, :role, :string
  end
end
