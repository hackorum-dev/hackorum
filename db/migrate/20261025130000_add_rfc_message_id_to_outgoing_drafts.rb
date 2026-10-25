class AddRfcMessageIdToOutgoingDrafts < ActiveRecord::Migration[8.0]
  def change
    add_column :outgoing_drafts, :rfc_message_id, :string
  end
end
