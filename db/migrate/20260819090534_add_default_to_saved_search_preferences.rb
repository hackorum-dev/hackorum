class AddDefaultToSavedSearchPreferences < ActiveRecord::Migration[8.0]
  def change
    add_column :saved_search_preferences, :default, :boolean, default: false, null: false

    add_index :saved_search_preferences, :user_id,
      unique: true,
      where: '"default" = true',
      name: "idx_one_default_saved_search_per_user"
  end
end
