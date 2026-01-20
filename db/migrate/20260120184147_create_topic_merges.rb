# frozen_string_literal: true

class CreateTopicMerges < ActiveRecord::Migration[8.0]
  def change
    create_table :topic_merges do |t|
      t.references :source_topic, null: false, foreign_key: { to_table: :topics }, index: { unique: true }
      t.references :target_topic, null: false, foreign_key: { to_table: :topics }
      t.references :merged_by, null: true, foreign_key: { to_table: :users }
      t.text :merge_reason

      t.timestamps
    end
  end
end
