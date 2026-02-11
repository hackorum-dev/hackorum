class CreateContributorMemberships < ActiveRecord::Migration[8.0]
  def change
    create_table :contributor_memberships do |t|
      t.references :person, null: false, foreign_key: true
      t.enum :contributor_type, enum_type: :contributor_type, null: false
      t.text :description
      t.timestamps
    end

    add_index :contributor_memberships, [ :person_id, :contributor_type ], unique: true, name: 'index_contributor_memberships_unique'
    add_index :contributor_memberships, :contributor_type
  end
end
