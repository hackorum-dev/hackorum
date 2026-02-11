class CreateAliases < ActiveRecord::Migration[8.0]
  def change
    create_table :aliases do |t|
      t.references :user, null: true, foreign_key: true
      t.string :name, null: false
      t.string :email, null: false
      t.boolean :primary_alias, null: false, default: false

      t.timestamps
    end

    add_index :aliases, [ :name, :email ], unique: true
  end
end
