class CreateAliasContributors < ActiveRecord::Migration[8.0]
  def change
    create_table :aliases_contributors do |t|
      t.references :alias, null: false, foreign_key: true
      t.references :contributor, null: false, foreign_key: true, index: false

      t.timestamps
    end

    add_index :aliases_contributors, [ :alias_id, :contributor_id ], unique: true, name: 'index_alias_contributors_unique'
    add_index :aliases_contributors, :contributor_id
  end
end
