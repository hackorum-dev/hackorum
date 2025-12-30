class CreateCommitfestTables < ActiveRecord::Migration[8.0]
  def change
    create_table :commitfests do |t|
      t.integer :external_id, null: false
      t.string :name, null: false
      t.string :status, null: false
      t.date :start_date, null: false
      t.date :end_date, null: false
      t.datetime :last_synced_at
      t.timestamps
    end

    add_index :commitfests, :external_id, unique: true

    create_table :commitfest_patches do |t|
      t.integer :external_id, null: false
      t.string :title, null: false
      t.string :topic
      t.string :target_version
      t.string :wikilink
      t.string :gitlink
      t.text :reviewers
      t.string :committer
      t.datetime :last_synced_at
      t.timestamps
    end

    add_index :commitfest_patches, :external_id, unique: true

    create_table :commitfest_patch_commitfests do |t|
      t.references :commitfest, null: false, foreign_key: true
      t.references :commitfest_patch, null: false, foreign_key: true
      t.string :status, null: false
      t.string :ci_status
      t.integer :ci_score
      t.datetime :last_synced_at
      t.timestamps
    end

    add_index :commitfest_patch_commitfests,
              %i[commitfest_id commitfest_patch_id],
              unique: true,
              name: "index_cf_patch_commitfests_unique"

    create_table :commitfest_tags do |t|
      t.string :name, null: false
      t.string :color
      t.string :description
      t.timestamps
    end

    add_index :commitfest_tags, :name, unique: true

    create_table :commitfest_patch_tags do |t|
      t.references :commitfest_patch, null: false, foreign_key: true
      t.references :commitfest_tag, null: false, foreign_key: true
      t.timestamps
    end

    add_index :commitfest_patch_tags,
              %i[commitfest_patch_id commitfest_tag_id],
              unique: true,
              name: "index_cf_patch_tags_unique"

    create_table :commitfest_patch_messages do |t|
      t.references :commitfest_patch, null: false, foreign_key: true
      t.string :message_id, null: false
      t.references :message_record, null: true, foreign_key: { to_table: :messages }
      t.datetime :last_synced_at
      t.timestamps
    end

    add_index :commitfest_patch_messages,
              %i[commitfest_patch_id message_id],
              unique: true,
              name: "index_cf_patch_messages_unique"

    create_table :commitfest_patch_topics do |t|
      t.references :commitfest_patch, null: false, foreign_key: true
      t.references :topic, null: false, foreign_key: true
      t.datetime :last_synced_at
      t.timestamps
    end

    add_index :commitfest_patch_topics,
              %i[commitfest_patch_id topic_id],
              unique: true,
              name: "index_cf_patch_topics_unique"
  end
end
