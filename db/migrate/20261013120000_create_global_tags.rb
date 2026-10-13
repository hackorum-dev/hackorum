class CreateGlobalTags < ActiveRecord::Migration[8.0]
  def up
    if select_value("SELECT 1 FROM name_reservations WHERE name = 'global'")
      raise "name 'global' is already reserved; free it before migrating"
    end

    create_table :global_tags do |t|
      t.string :name, null: false
      t.string :description
      t.datetime :retired_at
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :global_tags, :name, unique: true

    add_column :notes, :global, :boolean, null: false, default: false
    add_index :notes, :topic_id, where: "global", name: "index_notes_on_topic_id_global"
  end

  def down
    remove_index :notes, name: "index_notes_on_topic_id_global"
    remove_column :notes, :global
    drop_table :global_tags
  end
end
