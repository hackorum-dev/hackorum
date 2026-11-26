class CreateFeatureGroupVersions < ActiveRecord::Migration[8.0]
  def change
    create_table :feature_group_versions do |t|
      t.references :feature_group, null: false, foreign_key: true, index: false
      t.integer :major, null: false
      t.string :status, null: false
      t.string :source, null: false
      t.jsonb :details
      t.timestamps
    end
    add_index :feature_group_versions, [ :feature_group_id, :major ], unique: true
  end
end
