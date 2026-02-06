# frozen_string_literal: true

class AddFtsTsvectorColumns < ActiveRecord::Migration[8.0]
  def up
    # Add generated tsvector column for topics.title
    execute <<-SQL
      ALTER TABLE topics
      ADD COLUMN title_tsv tsvector
      GENERATED ALWAYS AS (to_tsvector('english', COALESCE(title, ''))) STORED;
    SQL

    add_index :topics, :title_tsv, using: :gin

    # Add generated tsvector column for messages.body
    execute <<-SQL
      ALTER TABLE messages
      ADD COLUMN body_tsv tsvector
      GENERATED ALWAYS AS (to_tsvector('english', COALESCE(body, ''))) STORED;
    SQL

    add_index :messages, :body_tsv, using: :gin
  end

  def down
    remove_index :messages, :body_tsv, if_exists: true
    execute "ALTER TABLE messages DROP COLUMN IF EXISTS body_tsv"

    remove_index :topics, :title_tsv, if_exists: true
    execute "ALTER TABLE topics DROP COLUMN IF EXISTS title_tsv"
  end
end
