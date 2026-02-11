class AddMessageReadRangesRecencyIndex < ActiveRecord::Migration[8.0]
  def change
    add_index :message_read_ranges, [ :user_id, :topic_id, :range_end_message_id ],
              order: { range_end_message_id: :desc },
              name: "index_message_read_ranges_on_user_topic_range_end_desc"
  end
end
