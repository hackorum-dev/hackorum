class AddTopicIdToCommitPeople < ActiveRecord::Migration[8.0]
  def up
    add_reference :commit_people, :topic, foreign_key: true, index: false
    add_index :commit_people, %i[commit_id topic_id]
    execute <<~SQL
      WITH cur AS (
        SELECT DISTINCT ON (topic_id) id, topic_id FROM patchset_runs
        WHERE status = 'done' ORDER BY topic_id, created_at DESC, id DESC
      ), owners AS (
        SELECT v.commit_id, min(v.topic_id) AS topic_id
        FROM commit_verdicts v JOIN cur ON cur.id = v.patchset_run_id
        WHERE v.verdict IN ('as_is', 'modified', 'partial', 'from_discussion')
        GROUP BY v.commit_id HAVING count(DISTINCT v.topic_id) = 1
      )
      UPDATE commit_people cp SET topic_id = owners.topic_id
      FROM owners WHERE cp.commit_id = owners.commit_id AND cp.source = 'llm'
    SQL
  end

  def down
    remove_reference :commit_people, :topic
  end
end
