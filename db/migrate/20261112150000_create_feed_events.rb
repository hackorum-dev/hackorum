class CreateFeedEvents < ActiveRecord::Migration[8.0]
  def change
    create_table :feed_events do |t|
      t.string :event_type, null: false
      t.datetime :occurred_at, null: false
      t.bigint :message_id
      t.bigint :patch_branch_id
      t.bigint :patch_ci_run_id
      t.bigint :author_person_id
      t.boolean :first_run
      t.string :previous_status
      t.boolean :verdict_changed
      # the time of the insert, not of the transaction
      t.datetime :created_at, null: false, default: -> { "(clock_timestamp() AT TIME ZONE 'UTC')" }
    end

    add_foreign_key :feed_events, :messages, on_delete: :cascade
    add_foreign_key :feed_events, :patch_branches, on_delete: :cascade
    add_foreign_key :feed_events, :patch_ci_runs, on_delete: :cascade

    add_index :feed_events, [ :author_person_id, :id ]
    add_index :feed_events, [ :event_type, :id ]
    add_index :feed_events, :created_at
    add_index :feed_events, :id, where: "verdict_changed IS NOT FALSE", name: "index_feed_events_without_repeats"

    add_index :feed_events, [ :message_id, :event_type ], unique: true,
              where: "patch_branch_id IS NULL AND patch_ci_run_id IS NULL",
              name: "index_feed_events_unique_message"
    add_index :feed_events, [ :patch_branch_id, :event_type ], unique: true,
              where: "patch_branch_id IS NOT NULL AND patch_ci_run_id IS NULL",
              name: "index_feed_events_unique_branch"
    add_index :feed_events, [ :patch_ci_run_id, :event_type ], unique: true,
              where: "patch_ci_run_id IS NOT NULL",
              name: "index_feed_events_unique_run"

    # cascade lookups
    add_index :feed_events, :message_id
    add_index :feed_events, :patch_branch_id, where: "patch_branch_id IS NOT NULL"
  end
end
