class AddSlugToTopics < ActiveRecord::Migration[8.0]
  def change
    add_column :topics, :slug, :string
    add_index :topics, :slug, unique: true
  end
end
