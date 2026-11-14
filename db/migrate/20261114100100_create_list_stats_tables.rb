class CreateListStatsTables < ActiveRecord::Migration[8.0]
  def change
    create_table :stats_person_weeks, id: false do |t|
      t.date :week, null: false
      t.bigint :person_id, null: false
      t.integer :list_bit, limit: 2, null: false
      t.integer :messages, null: false
      t.integer :threads, null: false
      t.integer :active_days, null: false
      t.integer :patch_mails, null: false
      t.integer :threads_started, null: false
    end
    add_index :stats_person_weeks, [ :week, :person_id, :list_bit ], unique: true
    add_index :stats_person_weeks, [ :person_id, :week ]

    create_table :stats_person_firsts, id: false do |t|
      t.bigint :person_id, null: false
      t.integer :list_bit, limit: 2, null: false
      t.datetime :first_at, null: false
      t.bigint :first_message_id, null: false
    end
    add_index :stats_person_firsts, [ :person_id, :list_bit ], unique: true

    create_table :stats_list_volume, id: false do |t|
      t.string :gran, null: false
      t.date :period_start, null: false
      t.integer :list_mask, null: false
      %i[messages messages_committer messages_contributor threads_new threads_active
         people people_committer people_contributor newcomers_community newcomers_selection].each do |c|
        t.integer c, null: false, default: 0
      end
    end
    add_index :stats_list_volume, [ :gran, :list_mask, :period_start ], unique: true

    create_table :stats_list_messages_by_list, id: false do |t|
      t.string :gran, null: false
      t.date :period_start, null: false
      t.integer :list_bit, limit: 2, null: false
      t.integer :messages, null: false
    end
    add_index :stats_list_messages_by_list, [ :gran, :list_bit, :period_start ], unique: true, name: "index_stats_list_messages_by_list_unique"

    create_table :stats_newcomers, id: false do |t|
      t.bigint :person_id, null: false
      t.datetime :first_at, null: false
      t.integer :first_list_mask, null: false
      t.string :path, null: false
      t.boolean :came_back, null: false
      t.integer :active_month_offsets, limit: 2, array: true, null: false, default: []
      t.integer :active_months_2y, null: false
      t.datetime :reached_top50_at
      t.boolean :contributor, null: false
      t.datetime :committer_at
    end
    add_index :stats_newcomers, :person_id, unique: true
    add_index :stats_newcomers, :first_at
  end
end
