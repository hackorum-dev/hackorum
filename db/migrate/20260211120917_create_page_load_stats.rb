class CreatePageLoadStats < ActiveRecord::Migration[8.0]
  def change
    create_table :page_load_stats do |t|
      t.string :url, null: false
      t.string :controller, null: false
      t.string :action, null: false
      t.float :render_time, null: false
      t.boolean :is_turbo, default: false, null: false
      t.datetime :created_at, null: false
    end

    add_index :page_load_stats, :created_at
    add_index :page_load_stats, [ :controller, :action ]
  end
end
