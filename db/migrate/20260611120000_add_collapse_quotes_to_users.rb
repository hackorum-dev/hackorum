class AddCollapseQuotesToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :collapse_quotes, :boolean, default: false, null: false
  end
end
