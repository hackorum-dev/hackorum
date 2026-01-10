class CreateTopicStars < ActiveRecord::Migration[8.0]
  def change
    create_table :topic_stars do |t|
      t.references :user, null: false, foreign_key: true
      t.references :topic, null: false, foreign_key: true

      t.timestamps
    end

    add_index :topic_stars, [:user_id, :topic_id], unique: true
  end
end
