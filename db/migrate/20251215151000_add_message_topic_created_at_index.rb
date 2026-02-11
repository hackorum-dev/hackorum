class AddMessageTopicCreatedAtIndex < ActiveRecord::Migration[8.0]
  def change
    add_index :messages, [ :topic_id, :created_at, :id ],
              order: { created_at: :desc, id: :desc },
              name: "index_messages_on_topic_id_and_created_at_desc_id_desc"
  end
end
