class CreateMailingListTables < ActiveRecord::Migration[8.0]
  def up
    create_table :mailing_lists do |t|
      t.string :identifier, null: false
      t.string :display_name, null: false
      t.string :email
      t.text :description
      t.timestamps
    end
    add_index :mailing_lists, :identifier, unique: true
    add_index :mailing_lists, :email, unique: true, where: "email IS NOT NULL"

    create_table :message_mailing_lists do |t|
      t.references :message, null: false, foreign_key: true
      t.references :mailing_list, null: false, foreign_key: true
      t.timestamps
    end
    add_index :message_mailing_lists, [ :message_id, :mailing_list_id ], unique: true, name: "idx_message_mailing_lists_unique"

    create_table :topic_mailing_lists do |t|
      t.references :topic, null: false, foreign_key: true
      t.references :mailing_list, null: false, foreign_key: true
      t.timestamps
    end
    add_index :topic_mailing_lists, [ :topic_id, :mailing_list_id ], unique: true, name: "idx_topic_mailing_lists_unique"

    hackers = execute <<~SQL
      INSERT INTO mailing_lists (identifier, display_name, email, created_at, updated_at)
      VALUES ('pgsql-hackers', 'hackers', 'pgsql-hackers@lists.postgresql.org', NOW(), NOW())
      RETURNING id
    SQL
    hackers_id = hackers.first["id"]

    execute <<~SQL
      INSERT INTO message_mailing_lists (message_id, mailing_list_id, created_at, updated_at)
      SELECT id, #{hackers_id}, NOW(), NOW() FROM messages
    SQL

    execute <<~SQL
      INSERT INTO topic_mailing_lists (topic_id, mailing_list_id, created_at, updated_at)
      SELECT id, #{hackers_id}, NOW(), NOW() FROM topics
    SQL
  end

  def down
    drop_table :topic_mailing_lists
    drop_table :message_mailing_lists
    drop_table :mailing_lists
  end
end
