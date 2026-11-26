class CreateFeatureGroups < ActiveRecord::Migration[8.0]
  def change
    create_table :feature_groups do |t|
      t.string :name, null: false
      t.string :slug, null: false
      t.text :summary
      t.string :source, null: false
      t.references :merged_into, foreign_key: { to_table: :feature_groups }
      t.bigint :created_by_run_id
      t.timestamps
    end
    add_index :feature_groups, :slug, unique: true

    create_table :feature_group_topics do |t|
      t.references :feature_group, foreign_key: true
      t.references :topic, null: false, foreign_key: true, index: { unique: true }
      t.string :source, null: false
      t.bigint :classification_run_id
      t.timestamps
    end
  end
end
