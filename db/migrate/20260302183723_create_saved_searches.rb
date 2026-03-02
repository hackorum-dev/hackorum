class CreateSavedSearches < ActiveRecord::Migration[8.0]
  def change
    create_enum :saved_search_scope, %w[global user team]

    create_table :saved_searches do |t|
      t.string :name, null: false
      t.text :query, null: false
      t.enum :scope, enum_type: :saved_search_scope, null: false, default: "global"
      t.references :user, foreign_key: true
      t.references :team, foreign_key: true
      t.integer :position, null: false, default: 0

      t.timestamps
    end

    add_index :saved_searches, [ :scope, :user_id, :team_id, :name ],
      unique: true, name: :idx_saved_searches_unique_name
    add_check_constraint :saved_searches,
      "NOT (user_id IS NOT NULL AND team_id IS NOT NULL)",
      name: :chk_saved_searches_single_owner

    create_table :saved_search_preferences do |t|
      t.references :saved_search, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.boolean :hidden, null: false, default: false

      t.timestamps
    end

    add_index :saved_search_preferences, [ :saved_search_id, :user_id ],
      unique: true, name: :idx_saved_search_prefs_unique
  end
end
