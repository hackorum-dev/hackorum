# frozen_string_literal: true

class CreateMessageMoves < ActiveRecord::Migration[8.0]
  def change
    create_table :message_moves do |t|
      t.references :topic_merge, null: false, foreign_key: true
      t.references :message, null: false, foreign_key: true

      t.timestamps
    end

    add_index :message_moves, [ :topic_merge_id, :message_id ], unique: true
  end
end
