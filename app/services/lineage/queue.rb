module Lineage
  class Queue
    PHASES = %w[trailer update discussion full lineage].freeze
    CUTOFF = ProfileStats::COMMIT_LINK_ERA_START
    GATED = %w[trailer discussion update].freeze

    def self.sweep! = PatchsetRun.stale_claims.delete_all

    # -> [topic, phase] or nil
    def self.next(phases: PHASES)
      phases.each do |phase|
        topic = phase_scope(phase).first
        return [ topic, phase ] if topic
      end
      nil
    end

    def self.phase_scope(phase, gate: true)
      raise ArgumentError, "unknown phase #{phase.inspect}" unless PHASES.include?(phase)
      linked = CommitTopic.trailer.select(:topic_id)
      scope = case phase
      when "trailer" then base.where(id: linked)
      when "update" then update
      when "discussion" then discussion(linked)
      when "full" then base.where.not(id: linked).where("s.first_at < ?", CUTOFF)
      when "lineage" then base.where.not(id: linked).where("s.first_at >= ? AND s.n >= 2", CUTOFF)
      end
      scope = scope.where("NOT #{held_sql('topics.id')}") if gate && GATED.include?(phase)
      scope.order(Arel.sql("s.last_at DESC, topics.id DESC"))
    end

    def self.counts
      PHASES.to_h do |phase|
        all = phase_scope(phase, gate: false).unscope(:order).count
        open = phase_scope(phase).unscope(:order).count
        [ phase, { remaining: open, held: all - open,
                   claimed: PatchsetRun.claimed.where(mode: phase).count,
                   done: PatchsetRun.done.where(mode: phase).count } ]
      end
    end

    # a higher-ranked thread sharing a trailer commit has not judged it yet
    def self.held_sql(t)
      <<~SQL.squish
        EXISTS (
          SELECT 1 FROM commit_topics ct
          JOIN commit_topics cu ON cu.commit_id = ct.commit_id AND cu.topic_id <> ct.topic_id AND cu.source = 'trailer'
          JOIN topics u ON u.id = cu.topic_id AND u.merged_into_topic_id IS NULL
          JOIN commits c ON c.id = ct.commit_id
          LEFT JOIN LATERAL (
            SELECT nr_r.id, nr_r.status FROM patchset_runs nr_r
            WHERE nr_r.topic_id = u.id AND nr_r.status <> 'queued'
            ORDER BY nr_r.created_at DESC, nr_r.id DESC LIMIT 1
          ) nr ON true
          WHERE ct.topic_id = #{t} AND ct.source = 'trailer'
            AND #{ThreadRank.before_sql('u.id', t)}
            AND (nr.id IS NULL
                 OR nr.status IN ('claimed', 'running')
                 OR (nr.status = 'done' AND #{Updates.unjudged_sql('nr.id')})
                 OR (nr.status = 'done'
                     AND EXISTS (SELECT 1 FROM lineage_rechecks lr
                                 WHERE lr.topic_id = u.id AND lr.commit_id = c.id AND lr.done_at IS NULL)))
        )
      SQL
    end

    def self.base
      submissions = Message.where(is_patch_submission: true).group(:topic_id)
                           .select("topic_id, min(created_at) AS first_at, max(created_at) AS last_at, count(*) AS n")
      Topic.active
           .joins("JOIN (#{submissions.to_sql}) s ON s.topic_id = topics.id")
           .where.not(id: PatchsetRun.blocking.select(:topic_id))
    end

    # trailer-linked threads nobody attached a patch to
    def self.discussion(linked)
      Topic.active
           .joins("JOIN (#{last_at(Message.where(topic_id: linked)).to_sql}) s ON s.topic_id = topics.id")
           .where(id: linked)
           .where.not(id: Message.where(is_patch_submission: true).select(:topic_id))
           .where.not(id: PatchsetRun.blocking.select(:topic_id))
    end

    # newest run done, so nothing claimed or failed after it
    def self.update
      Topic.active
           .joins("JOIN (#{Updates::NEWEST_RUNS_SQL}) r ON r.topic_id = topics.id AND r.status = 'done'")
           .joins("JOIN (#{last_at(Message.where(topic_id: PatchsetRun.done.select(:topic_id))).to_sql}) s ON s.topic_id = topics.id")
           .where("#{Updates.new_commit_sql('topics.id', 'r.id')} OR #{Updates.new_patch_sql('topics.id', 'r')} OR #{Updates.recheck_sql('topics.id')}")
    end

    def self.last_at(messages)
      messages.group(:topic_id).select("topic_id, max(created_at) AS last_at")
    end
    private_class_method :held_sql, :base, :discussion, :update, :last_at
  end
end
