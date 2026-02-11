# frozen_string_literal: true

class CreateThreadAwarenesses < ActiveRecord::Migration[7.1]
  def change
    create_table :thread_awarenesses do |t|
      t.references :user, null: false, foreign_key: true
      t.references :topic, null: false, foreign_key: true
      t.bigint :aware_until_message_id, null: false
      t.datetime :aware_at, null: false

      t.timestamps
    end

    add_index :thread_awarenesses, [ :user_id, :topic_id ], unique: true
  end
end
