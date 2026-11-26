class CreateFeatureGroupDismissedPairs < ActiveRecord::Migration[8.0]
  def change
    create_table :feature_group_dismissed_pairs do |t|
      t.references :low, null: false, foreign_key: { to_table: :feature_groups, on_delete: :cascade }, index: false
      t.references :high, null: false, foreign_key: { to_table: :feature_groups, on_delete: :cascade }
      t.datetime :created_at, null: false
    end
    add_index :feature_group_dismissed_pairs, [ :low_id, :high_id ], unique: true
  end
end
