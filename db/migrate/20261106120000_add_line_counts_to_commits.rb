class AddLineCountsToCommits < ActiveRecord::Migration[8.0]
  def change
    add_column :commits, :lines_added, :integer
    add_column :commits, :lines_removed, :integer
  end
end
