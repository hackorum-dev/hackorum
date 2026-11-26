class CreateClassificationRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :classification_runs do |t|
      t.references :topic, null: false, foreign_key: true, index: false
      t.string :status, null: false
      t.string :phase
      t.string :worker
      t.datetime :claimed_at
      t.datetime :started_at
      t.datetime :finished_at
      t.float :duration_s
      t.integer :message_count
      t.bigint :through_message_id
      t.string :model
      t.string :effort
      t.string :prompt_version
      t.integer :input_tokens
      t.integer :cached_input_tokens
      t.integer :output_tokens
      t.jsonb :result
      t.string :kind
      t.string :size
      t.boolean :not_a_bug
      t.references :feature_group, foreign_key: { on_delete: :nullify }
      t.text :error
      t.string :failure_kind
      t.timestamps
    end
    add_index :classification_runs, [ :topic_id, :created_at ]
    add_index :classification_runs, [ :status, :claimed_at ]

    add_foreign_key :feature_groups, :classification_runs, column: :created_by_run_id, on_delete: :nullify
    add_foreign_key :feature_group_topics, :classification_runs, column: :classification_run_id, on_delete: :nullify
  end
end
