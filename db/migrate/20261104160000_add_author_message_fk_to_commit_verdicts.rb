class AddAuthorMessageFkToCommitVerdicts < ActiveRecord::Migration[8.0]
  def change
    add_index :commit_verdicts, :author_message_id
    add_foreign_key :commit_verdicts, :messages, column: :author_message_id, on_delete: :nullify
  end
end
