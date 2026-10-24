class AddVerifiedAtToUsers < ActiveRecord::Migration[8.0]
  def up
    add_column :users, :verified_at, :datetime
    add_index :users, :created_at, where: "verified_at IS NULL", name: "index_users_unverified_on_created_at"

    execute "UPDATE users SET verified_at = created_at"

    # Pending registrations used to live in user_tokens only; drop them.
    execute "DELETE FROM name_reservations WHERE owner_type = 'UserToken'"
    execute "DELETE FROM user_tokens WHERE purpose = 'register'"
  end

  def down
    remove_index :users, name: "index_users_unverified_on_created_at"
    remove_column :users, :verified_at
  end
end
