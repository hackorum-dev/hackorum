class CreatePatchsetLineage < ActiveRecord::Migration[8.0]
  def change
    create_table :patchset_runs do |t|
      t.bigint :topic_id, null: false
      t.string :status, null: false, default: "queued"
      t.string :model
      t.string :effort
      t.string :prompt_version
      t.datetime :started_at
      t.datetime :finished_at
      t.float :duration_s
      t.integer :input_tokens
      t.integer :cached_input_tokens
      t.integer :output_tokens
      t.integer :exit_code
      t.bigint :through_message_id
      t.string :job_dir
      t.text :story
      t.jsonb :raw_result
      t.text :error
      t.timestamps
    end
    add_index :patchset_runs, [ :topic_id, :created_at ]

    create_table :patchset_pairs do |t|
      t.bigint :topic_id, null: false
      t.bigint :later_message_id, null: false
      t.bigint :earlier_message_id, null: false
      t.jsonb :metrics, null: false, default: {}
    end
    add_index :patchset_pairs, [ :later_message_id, :earlier_message_id ], unique: true,
              name: "index_patchset_pairs_on_message_pair"
    add_index :patchset_pairs, :topic_id

    create_table :patchset_lineages do |t|
      t.bigint :topic_id, null: false
      t.bigint :patchset_run_id, null: false
      t.bigint :message_id, null: false
      t.bigint :parent_message_id
      t.string :step_kind, null: false
      t.float :confidence, null: false
      t.text :reason
    end
    add_index :patchset_lineages, [ :patchset_run_id, :message_id ], unique: true
    add_index :patchset_lineages, :topic_id

    create_table :commit_verdicts do |t|
      t.bigint :topic_id, null: false
      t.bigint :patchset_run_id, null: false
      t.bigint :commit_id, null: false
      t.string :verdict, null: false
      t.bigint :source_message_id
      t.float :confidence, null: false
      t.text :evidence
    end
    add_index :commit_verdicts, [ :patchset_run_id, :commit_id ], unique: true
    add_index :commit_verdicts, :topic_id
    add_index :commit_verdicts, :commit_id

    add_column :commit_topics, :source, :string, null: false, default: "trailer"
    add_column :commit_topics, :confidence, :float
    add_column :patch_branches, :lineage_only, :boolean, null: false, default: false

    add_foreign_key :patchset_runs, :topics
    add_foreign_key :patchset_pairs, :topics
    add_foreign_key :patchset_pairs, :messages, column: :later_message_id
    add_foreign_key :patchset_pairs, :messages, column: :earlier_message_id
    add_foreign_key :patchset_lineages, :patchset_runs, on_delete: :cascade
    add_foreign_key :patchset_lineages, :topics
    add_foreign_key :patchset_lineages, :messages
    add_foreign_key :patchset_lineages, :messages, column: :parent_message_id, on_delete: :nullify
    add_foreign_key :commit_verdicts, :patchset_runs, on_delete: :cascade
    add_foreign_key :commit_verdicts, :topics
    add_foreign_key :commit_verdicts, :commits
    add_foreign_key :commit_verdicts, :messages, column: :source_message_id, on_delete: :nullify
  end
end
