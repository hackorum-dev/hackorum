class CreateTopicLinks < ActiveRecord::Migration[8.0]
  def change
    create_table :topic_links do |t|
      t.references :topic, null: false, foreign_key: true, index: false
      t.references :other_topic, null: false, foreign_key: { to_table: :topics }, index: false
      t.string :kind, null: false
      t.string :direction, null: false
      t.string :ref_type, null: false
      t.bigint :ref_id, null: false
      t.datetime :created_at, null: false
    end
    add_index :topic_links, %i[topic_id other_topic_id kind ref_type ref_id], unique: true, name: "index_topic_links_unique"
    add_index :topic_links, :other_topic_id
    add_index :topic_links, %i[ref_type ref_id]
  end
end
