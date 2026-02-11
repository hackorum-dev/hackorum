# frozen_string_literal: true

class CreateMessageReadRanges < ActiveRecord::Migration[7.1]
  def change
    create_table :message_read_ranges do |t|
      t.references :user, null: false, foreign_key: true
      t.references :topic, null: false, foreign_key: true
      t.bigint :range_start_message_id, null: false
      t.bigint :range_end_message_id, null: false
      t.datetime :read_at, null: false

      t.timestamps
    end

    add_index :message_read_ranges, [ :user_id, :topic_id, :range_start_message_id, :range_end_message_id ], name: "index_message_read_ranges_on_user_topic_range"
  end
end
