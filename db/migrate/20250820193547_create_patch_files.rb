class CreatePatchFiles < ActiveRecord::Migration[8.0]
  def change
    create_table :patch_files do |t|
      t.references :attachment, null: false, foreign_key: true
      t.string :filename, null: false
      t.string :status # added, modified, deleted, renamed
      t.integer :line_changes
      t.string :old_filename # for renames

      t.timestamps
    end

    add_index :patch_files, :filename
    add_index :patch_files, [ :attachment_id, :filename ], unique: true
  end
end
