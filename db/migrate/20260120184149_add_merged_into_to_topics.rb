# frozen_string_literal: true

class AddMergedIntoToTopics < ActiveRecord::Migration[8.0]
  def change
    add_reference :topics, :merged_into_topic, foreign_key: { to_table: :topics }, null: true
  end
end
