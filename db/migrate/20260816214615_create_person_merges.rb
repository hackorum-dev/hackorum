class CreatePersonMerges < ActiveRecord::Migration[8.0]
  # No foreign key on either person column on purpose. The source row is gone
  # by the time the merge finishes, and a target can itself be merged away
  # later, so a real FK would either block the merge or delete its own audit
  # trail. The snapshot columns carry what the ids can no longer resolve.
  def change
    create_table :person_merges do |t|
      t.references :performed_by, null: false, foreign_key: { to_table: :users }
      t.bigint :source_person_id, null: false
      t.bigint :target_person_id, null: false
      t.string :source_name
      t.string :target_name
      t.string :source_emails, array: true, default: [], null: false
      t.integer :aliases_moved, default: 0, null: false
      t.integer :topics_moved, default: 0, null: false
      t.integer :messages_moved, default: 0, null: false
      t.timestamps
    end

    add_index :person_merges, :target_person_id
  end
end
