class AddOrphanReplyIndexToMessages < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  def change
    add_index :messages, :reply_to_message_id,
              where: "reply_to_id IS NULL AND reply_to_message_id IS NOT NULL",
              name: "index_messages_on_orphan_reply_to_message_id",
              algorithm: :concurrently, if_not_exists: true
  end
end
