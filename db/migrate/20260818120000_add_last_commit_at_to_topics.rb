class AddLastCommitAtToTopics < ActiveRecord::Migration[8.0]
  def up
    add_column :topics, :last_commit_at, :datetime, precision: 6

    # no index: every reader reaches topics by primary key off a join it
    # already needs, and the predicate compares this against a column in
    # another table, so there is nothing to index
    execute <<~SQL
      UPDATE topics SET last_commit_at = sub.m
      FROM (SELECT ct.topic_id, MAX(c.committed_at) AS m
            FROM commit_topics ct JOIN commits c ON c.id = ct.commit_id
            GROUP BY ct.topic_id) sub
      WHERE topics.id = sub.topic_id
    SQL
  end

  def down
    remove_column :topics, :last_commit_at
  end
end
