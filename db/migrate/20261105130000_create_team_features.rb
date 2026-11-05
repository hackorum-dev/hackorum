class CreateTeamFeatures < ActiveRecord::Migration[8.0]
  def change
    create_table :team_features do |t|
      t.references :team, null: false, foreign_key: { on_delete: :cascade }
      t.string :feature, null: false
      t.datetime :created_at, null: false
    end
    add_index :team_features, [ :team_id, :feature ], unique: true
  end
end
