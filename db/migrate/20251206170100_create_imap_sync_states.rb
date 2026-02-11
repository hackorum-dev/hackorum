# frozen_string_literal: true

class CreateImapSyncStates < ActiveRecord::Migration[7.1]
  def change
    create_table :imap_sync_states do |t|
      t.string :mailbox_label, null: false, default: 'INBOX'
      t.bigint :last_uid, null: false, default: 0
      t.datetime :last_checked_at
      t.text :last_error

      t.timestamps
    end

    add_index :imap_sync_states, :mailbox_label, unique: true
  end
end
