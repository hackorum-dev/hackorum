class AddApiTokenRefsToOutgoingDrafts < ActiveRecord::Migration[8.0]
  def change
    add_column :outgoing_drafts, :created_via_token_id, :bigint
    add_column :outgoing_drafts, :last_edited_via_token_id, :bigint
    add_foreign_key :outgoing_drafts, :api_tokens, column: :created_via_token_id, on_delete: :nullify
    add_foreign_key :outgoing_drafts, :api_tokens, column: :last_edited_via_token_id, on_delete: :nullify
  end
end
