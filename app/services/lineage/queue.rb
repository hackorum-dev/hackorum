module Lineage
  class Queue
    PHASES = %w[trailer full lineage].freeze
    CUTOFF = ProfileStats::COMMIT_LINK_ERA_START

    def self.sweep! = PatchsetRun.stale_claims.delete_all

    # -> [topic, phase] or nil
    def self.next(phases: PHASES)
      phases.each do |phase|
        topic = phase_scope(phase).first
        return [ topic, phase ] if topic
      end
      nil
    end

    def self.phase_scope(phase)
      raise ArgumentError, "unknown phase #{phase.inspect}" unless PHASES.include?(phase)
      linked = CommitTopic.trailer.select(:topic_id)
      scope = case phase
      when "trailer" then base.where(id: linked)
      when "full" then base.where.not(id: linked).where("s.first_at < ?", CUTOFF)
      when "lineage" then base.where.not(id: linked).where("s.first_at >= ? AND s.n >= 2", CUTOFF)
      end
      scope.order(Arel.sql("s.last_at DESC, topics.id DESC"))
    end

    def self.counts
      PHASES.to_h do |phase|
        [ phase, { remaining: phase_scope(phase).unscope(:order).count,
                   claimed: PatchsetRun.claimed.where(mode: phase).count,
                   done: PatchsetRun.done.where(mode: phase).count } ]
      end
    end

    def self.base
      submissions = Message.where(is_patch_submission: true).group(:topic_id)
                           .select("topic_id, min(created_at) AS first_at, max(created_at) AS last_at, count(*) AS n")
      Topic.active
           .joins("JOIN (#{submissions.to_sql}) s ON s.topic_id = topics.id")
           .where.not(id: PatchsetRun.blocking.select(:topic_id))
    end
    private_class_method :base
  end
end
