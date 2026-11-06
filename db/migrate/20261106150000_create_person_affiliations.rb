class CreatePersonAffiliations < ActiveRecord::Migration[8.0]
  def change
    create_table :person_affiliations do |t|
      t.references :person, null: false, foreign_key: { on_delete: :cascade }
      t.string :company, null: false
      t.date :since
      t.date :until
      t.string :source, null: false
      t.text :note
      t.timestamps
    end
    add_index :person_affiliations, [ :person_id, :company, :since ], unique: true, nulls_not_distinct: true
  end
end
