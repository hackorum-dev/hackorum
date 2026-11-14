class AddArchivedToMailingLists < ActiveRecord::Migration[8.0]
  def up
    add_column :mailing_lists, :archived, :boolean, default: false, null: false
    execute "UPDATE mailing_lists SET archived = true WHERE identifier = 'pgsql-patches'"
  end

  def down
    remove_column :mailing_lists, :archived
  end
end
