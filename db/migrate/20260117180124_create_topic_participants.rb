class CreateTopicParticipants < ActiveRecord::Migration[8.0]
  def change
    create_table :topic_participants do |t|
      t.references :topic, null: false, foreign_key: true, index: false
      t.references :person, null: false, foreign_key: true
      t.integer :message_count, null: false, default: 0
      t.datetime :first_message_at, null: false
      t.datetime :last_message_at, null: false
      t.boolean :is_contributor, null: false, default: false
      t.timestamps

      t.index [ :topic_id, :message_count ], order: { message_count: :desc }
      t.index [ :topic_id ], where: "is_contributor = true", name: "idx_topic_participants_contributors"
      t.index [ :topic_id, :person_id ], unique: true
      t.index [ :person_id, :last_message_at ], order: { last_message_at: :desc }
    end
  end
end
