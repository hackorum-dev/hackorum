class AddMessageCountToMessageReadRanges < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  class MigrationMessageReadRange < ApplicationRecord
    self.table_name = "message_read_ranges"
  end

  class MigrationMessage < ApplicationRecord
    self.table_name = "messages"
  end

  def up
    add_column :message_read_ranges, :message_count, :integer, default: 0, null: false

    say_with_time "Backfilling message_count for existing message_read_ranges" do
      MigrationMessageReadRange.reset_column_information

      MigrationMessageReadRange.find_in_batches(batch_size: 500) do |batch|
        updates = batch.map do |range|
          count = MigrationMessage.where(topic_id: range.topic_id, id: range.range_start_message_id..range.range_end_message_id).count
          [ range.id, count ]
        end

        updates.each_slice(100) do |slice|
          slice.each do |id, count|
            MigrationMessageReadRange.where(id: id).update_all(message_count: count)
          end
        end
      end
    end
  end

  def down
    remove_column :message_read_ranges, :message_count
  end
end
