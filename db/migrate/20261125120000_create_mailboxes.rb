class CreateMailboxes < ActiveRecord::Migration[8.0]
  def change
    create_table :mailboxes do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.string :password_hash, null: false
      t.integer :quota_mb, null: false, default: 5120
      t.datetime :disabled_at
      t.timestamps
    end
    create_table :mailbox_addresses do |t|
      t.references :mailbox, null: false, foreign_key: true
      t.string :local_part, null: false
      t.boolean :login, null: false, default: false
      t.timestamps
    end
    add_index :mailbox_addresses, :local_part, unique: true
    add_index :mailbox_addresses, :mailbox_id, unique: true, where: "login", name: "index_mailbox_addresses_one_login"
  end
end
