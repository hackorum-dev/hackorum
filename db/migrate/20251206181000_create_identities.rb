class CreateIdentities < ActiveRecord::Migration[8.0]
  def change
    create_table :identities do |t|
      t.references :user, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :uid, null: false
      t.string :email
      t.text :raw_info
      t.datetime :last_used_at

      t.timestamps
    end

    add_index :identities, [ :provider, :uid ], unique: true
    # Functional index for email lookups
    execute <<~SQL
      CREATE INDEX IF NOT EXISTS index_identities_on_lower_trim_email
      ON identities (lower(trim(email)));
    SQL
  end
end
