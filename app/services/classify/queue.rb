module Classify
  class Queue
    PHASES = ClassificationRun::PHASES
    NEW_MIN_AGE = 6.hours
    NEW_WINDOW = 14.days
    BACKOFF_DAYS = [ 1, 2, 4, 8, 16, 32 ].freeze
    SETTLED_MIN_MESSAGES = 30
    SETTLED_GAP = 90.days
    CLAIM_TTL = ClassificationRun::CLAIM_TTL

    def self.sweep! = ClassificationRun.stale_claims.delete_all

    # -> [topic, phase] or nil
    def self.next(phases: PHASES)
      (PHASES & phases).each do |phase|
        topic = phase_scope(phase).first
        return [ topic, phase ] if topic
      end
      nil
    end

    def self.phase_scope(phase)
      raise ArgumentError, "unknown phase #{phase.inspect}" unless PHASES.include?(phase)
      now = Time.current
      case phase
      when "new"
        unclassified(Scope.topics.where("topics.last_message_at > ?", now - NEW_WINDOW))
          .where("f.first_at <= ? AND f.first_at > ?", now - NEW_MIN_AGE, now - NEW_WINDOW)
          .order(Arel.sql("f.first_at DESC, topics.id DESC"))
      when "backfill"
        unclassified(Scope.in_window)
          .where("f.first_at <= ?", now - NEW_WINDOW)
          .order(Arel.sql("topics.last_message_at DESC, topics.id DESC"))
      when "recheck"
        recheck.where("due.due_at <= ?", now).order(Arel.sql("due.due_at, topics.id"))
      end
    end

    def self.counts
      PHASES.to_h do |phase|
        [ phase, { remaining: phase_scope(phase).unscope(:order).count,
                   claimed: ClassificationRun.claimed.where(phase:).count,
                   done: ClassificationRun.done.where(phase:).count } ]
      end
    end

    def self.unclassified(topics)
      topics.where.not(id: ClassificationRun.select(:topic_id))
            .joins("JOIN LATERAL (SELECT min(m.created_at) AS first_at FROM messages m WHERE m.topic_id = topics.id) f ON true")
    end

    # latest run done, new messages since, not fully locked; due_at from the backoff
    def self.recheck
      latest = ClassificationRun.latest_for(ClassificationRun.done.select(:topic_id))
      Scope.topics
           .joins("JOIN (#{latest.to_sql}) r ON r.topic_id = topics.id AND r.status = 'done'")
           .joins(<<~SQL.squish)
             JOIN LATERAL (
               SELECT count(*)::int AS n FROM classification_runs c
               WHERE c.topic_id = topics.id AND c.status = 'done'
             ) d ON true
             LEFT JOIN LATERAL (
               SELECT p.kind, p.size, p.enhancement, p.not_a_bug, p.feature_group_id FROM classification_runs p
               WHERE p.topic_id = topics.id AND p.status = 'done'
               ORDER BY p.created_at DESC, p.id DESC OFFSET 1 LIMIT 1
             ) prev ON true
             JOIN LATERAL (
               SELECT COALESCE(r.finished_at, r.created_at) + CASE
                 WHEN topics.message_count >= #{SETTLED_MIN_MESSAGES} AND d.n >= 2
                      AND ROW(prev.kind, prev.size, prev.enhancement, prev.not_a_bug, prev.feature_group_id)
                          IS NOT DISTINCT FROM ROW(r.kind, r.size, r.enhancement, r.not_a_bug, r.feature_group_id)
                 THEN make_interval(secs => #{SETTLED_GAP.to_i})
                 ELSE make_interval(days => COALESCE((ARRAY[#{BACKOFF_DAYS.join(', ')}])[d.n], #{BACKOFF_DAYS.last}))
               END AS due_at
             ) due ON true
           SQL
           .where("topics.message_count > r.message_count")
           .where.not(id: ClassificationRun.claimed.select(:topic_id))
           .where("NOT #{fully_locked_sql}")
    end

    # as BotNote#locked?, and no membership the bot may still change
    def self.fully_locked_sql
      bot_id = User.where(username: BOT_USERNAME).pick(:id)
      return "false" unless bot_id

      <<~SQL.squish
        (EXISTS (
           SELECT 1 FROM (
             SELECT n.deleted_at, n.last_editor_id FROM notes n
             WHERE n.topic_id = topics.id AND n.global AND n.author_id = #{bot_id}
             ORDER BY n.id DESC LIMIT 1
           ) bn
           WHERE bn.deleted_at IS NOT NULL OR (bn.last_editor_id IS NOT NULL AND bn.last_editor_id <> #{bot_id})
         )
         AND NOT EXISTS (
           SELECT 1 FROM feature_group_topics fgt WHERE fgt.topic_id = topics.id AND fgt.source <> 'human'
         ))
      SQL
    end
    private_class_method :unclassified, :recheck, :fully_locked_sql
  end
end
