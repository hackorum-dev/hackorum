class CreateLineageRechecks < ActiveRecord::Migration[8.0]
  def change
    create_table :lineage_rechecks do |t|
      t.references :topic, null: false, foreign_key: true
      t.references :commit, null: false, foreign_key: true
      t.references :requested_by_run, foreign_key: { to_table: :patchset_runs, on_delete: :nullify }
      t.datetime :created_at, null: false
      t.datetime :done_at
    end
    add_index :lineage_rechecks, %i[topic_id commit_id], unique: true, where: "done_at IS NULL",
              name: "index_lineage_rechecks_open"
  end
end
