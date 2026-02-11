class CreateNotesAndActivities < ActiveRecord::Migration[8.0]
  def change
    create_table :notes do |t|
      t.references :topic, null: false, foreign_key: true
      t.references :message, foreign_key: true
      t.references :author, null: false, foreign_key: { to_table: :users }
      t.references :last_editor, foreign_key: { to_table: :users }
      t.text :body, null: false
      t.datetime :deleted_at

      t.timestamps
    end

    create_table :note_mentions do |t|
      t.references :note, null: false, foreign_key: true
      t.string :mentionable_type, null: false
      t.bigint :mentionable_id, null: false

      t.timestamps

      t.index [ :note_id, :mentionable_type, :mentionable_id ], unique: true, name: "index_note_mentions_unique"
      t.index [ :mentionable_type, :mentionable_id ]
    end

    create_table :note_tags do |t|
      t.references :note, null: false, foreign_key: true
      t.string :tag, null: false

      t.timestamps

      t.index [ :note_id, :tag ], unique: true
      t.index :tag
    end

    create_table :note_edits do |t|
      t.references :note, null: false, foreign_key: true
      t.references :editor, null: false, foreign_key: { to_table: :users }
      t.text :body, null: false

      t.timestamps
    end

    create_table :activities do |t|
      t.references :user, null: false, foreign_key: true
      t.string :activity_type, null: false
      t.string :subject_type, null: false
      t.bigint :subject_id, null: false
      t.jsonb :payload
      t.datetime :read_at
      t.boolean :hidden, null: false, default: false

      t.timestamps

      t.index [ :user_id, :read_at ]
      t.index [ :user_id, :id ]
      t.index [ :subject_type, :subject_id ]
    end
  end
end
