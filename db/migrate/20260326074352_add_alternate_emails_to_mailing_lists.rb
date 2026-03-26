class AddAlternateEmailsToMailingLists < ActiveRecord::Migration[8.0]
  def change
    add_column :mailing_lists, :alternate_emails, :string, array: true, default: []
  end
end
