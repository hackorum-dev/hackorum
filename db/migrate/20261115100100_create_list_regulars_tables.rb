class CreateListRegularsTables < ActiveRecord::Migration[8.0]
  def change
    create_table :stats_regulars_monthly, id: false do |t|
      t.date :month, null: false
      t.integer :list_mask, null: false
      t.bigint :person_id, null: false
      t.float :score_messages, null: false
      t.float :score_threads, null: false
      t.float :score_days, null: false
      t.integer :rank_messages, null: false
      t.integer :rank_threads, null: false
      t.integer :rank_days, null: false
    end
    add_index :stats_regulars_monthly, [ :list_mask, :month, :person_id ], unique: true, name: "index_stats_regulars_monthly_unique"
    add_index :stats_regulars_monthly, [ :list_mask, :person_id ]

    create_table :stats_regulars_totals, id: false do |t|
      t.date :month, null: false
      t.integer :list_mask, null: false
      t.float :total_messages, null: false
      t.float :total_threads, null: false
      t.float :total_days, null: false
    end
    add_index :stats_regulars_totals, [ :list_mask, :month ], unique: true

    add_column :stats_newcomers, :second_at, :datetime
  end
end
