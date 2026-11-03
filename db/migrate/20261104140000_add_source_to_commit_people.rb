class AddSourceToCommitPeople < ActiveRecord::Migration[8.0]
  def change
    add_column :commit_people, :source, :string, null: false, default: "parsed"
    add_column :commit_people, :confidence, :float
  end
end
