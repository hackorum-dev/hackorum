class AddAuthorToCommitVerdicts < ActiveRecord::Migration[8.0]
  def change
    add_column :commit_verdicts, :author_name, :string
    add_column :commit_verdicts, :author_message_id, :bigint
  end
end
