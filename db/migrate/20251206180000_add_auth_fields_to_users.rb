class AddAuthFieldsToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :password_digest, :string
    add_column :users, :admin, :boolean, null: false, default: false
    add_column :users, :deleted_at, :datetime
    add_index :users, :deleted_at
  end
end
