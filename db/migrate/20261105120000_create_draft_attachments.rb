class CreateDraftAttachments < ActiveRecord::Migration[8.0]
  def change
    create_table :draft_attachments do |t|
      t.references :outgoing_draft, null: false, foreign_key: { on_delete: :cascade }
      t.string :file_name, null: false
      t.string :content_type
      t.text :body, null: false
      t.integer :byte_size, null: false
      t.timestamps
    end
  end
end
