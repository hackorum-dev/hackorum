class AddEnhancementToClassificationRuns < ActiveRecord::Migration[8.0]
  def change
    add_column :classification_runs, :enhancement, :boolean
  end
end
