module Lineage
  # Judged means a verdict in the newest done run, so every update run must
  # carry earlier verdicts forward and answer every candidate, or it loops.
  module Updates
    NEWEST_RUNS_SQL = "SELECT DISTINCT ON (topic_id) id, topic_id, status, through_message_id, bundle_index " \
                      "FROM patchset_runs WHERE status <> 'queued' ORDER BY topic_id, created_at DESC, id DESC".freeze

    # topic_id and run_id are SQL expressions; the commit is aliased c
    def self.new_commit_sql(topic_id, run_id)
      <<~SQL.squish
        EXISTS (SELECT 1 FROM commit_topics ct JOIN commits c ON c.id = ct.commit_id
                WHERE ct.topic_id = #{topic_id} AND ct.source = 'trailer' AND #{unjudged_sql(run_id)})
      SQL
    end

    # new patch mail is mail the run did not see: its patch_mail_ids, else its
    # patchsets, else dates
    def self.new_patch_sql(topic_id, run)
      <<~SQL.squish
        EXISTS (SELECT 1 FROM messages m LEFT JOIN messages t ON t.id = #{run}.through_message_id
                WHERE m.topic_id = #{topic_id} AND m.is_patch_submission
                  AND CASE WHEN jsonb_typeof(#{run}.bundle_index->'patch_mail_ids') = 'array'
                           THEN NOT (#{run}.bundle_index->'patch_mail_ids' @> jsonb_build_array(m.id))
                           WHEN jsonb_typeof(#{run}.bundle_index->'patchsets') = 'array'
                           THEN NOT (#{run}.bundle_index->'patchsets' @> jsonb_build_array(jsonb_build_object('message_id', m.id)))
                           ELSE (t.id IS NULL OR m.created_at > t.created_at) END)
      SQL
    end

    def self.new_patchset_ids(run, messages)
      seen = run.bundle_index.is_a?(Hash) && run.bundle_index["patchsets"]
      seen = seen.is_a?(Array) ? seen.map { |p| p["message_id"] }.to_set : nil
      through = run.through_message
      messages.reject { |m|
        seen ? seen.include?(m.id) : through && m.created_at <= through.created_at
      }.map(&:id).to_set
    end

    # guidance only: arrived after the through message, by id or by date
    def self.new_message?(run, message)
      through = run.through_message
      through.nil? || message.id > through.id || message.created_at > through.created_at
    end

    def self.unjudged_sql(run_id)
      <<~SQL.squish
        NOT EXISTS (SELECT 1 FROM commit_verdicts v JOIN commits vc ON vc.id = v.commit_id
                    WHERE v.patchset_run_id = #{run_id}
                      AND (COALESCE(vc.cherry_picked_from_sha, vc.sha) = COALESCE(c.cherry_picked_from_sha, c.sha)
                           OR vc.sha = c.cherry_picked_from_sha))
      SQL
    end

    def self.recheck_sql(topic_id)
      "EXISTS (SELECT 1 FROM lineage_rechecks lr WHERE lr.topic_id = #{topic_id} AND lr.done_at IS NULL)"
    end

    def self.recheck_commits(topic)
      Commit.where(id: LineageRecheck.open.where(topic_id: topic.id).select(:commit_id)).order(:committed_at, :id).to_a
    end

    def self.new_commits(topic, run)
      Commit.from("commits c").select("c.*")
            .where("c.id IN (SELECT commit_id FROM commit_topics WHERE topic_id = ? AND source = 'trailer')", topic.id)
            .where(unjudged_sql("?"), run.id)
            .order("c.committed_at DESC, c.id").to_a
    end
  end
end
