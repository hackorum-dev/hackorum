class AllowNullPersonOnUsers < ActiveRecord::Migration[8.0]
  def up
    change_column_null :users, :person_id, true
    execute "UPDATE users SET person_id = NULL WHERE deleted_at IS NOT NULL"
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
