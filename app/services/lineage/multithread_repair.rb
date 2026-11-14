module Lineage
  class MultithreadRepair
    CURRENT = "SELECT DISTINCT ON (topic_id) id FROM patchset_runs WHERE status = 'done' ORDER BY topic_id, created_at DESC, id DESC".freeze

    def rows
      @rows ||= begin
        linked = CommitTopic.trailer.joins(:topic).merge(Topic.active).pluck(:commit_id, :topic_id).to_set
        CommitVerdict.where("patchset_run_id IN (#{CURRENT})")
                     .pluck(:commit_id, :topic_id, :verdict)
                     .select { |c, t, _| linked.include?([ c, t ]) }
                     .group_by(&:first)
                     .select { |_, vs| vs.count { |_, _, v| CommitVerdict::COMMITTED.include?(v) } >= 2 }
      end
    end

    def plan
      topics = rows.values.flatten(1).map { |_, t, _| t }.uniq
      avg = PatchsetRun.done.where(mode: "update").average(:input_tokens).to_f
      { commits: rows.size, topics: topics.size,
        pairs: rows.values.map { |vs| vs.map(&:last).sort.join("+") }.tally,
        est_input_tokens: (avg * topics.size).round }
    end

    def apply!
      wanted = rows.flat_map { |cid, vs| vs.map { |_, t, _| [ t, cid ] } }.uniq
      open = LineageRecheck.open.pluck(:topic_id, :commit_id).to_set
      fresh = wanted.reject { |pair| open.include?(pair) }
      now = Time.current
      LineageRecheck.insert_all(fresh.map { |t, c| { topic_id: t, commit_id: c, created_at: now } }) if fresh.any?
      fresh.size
    end
  end
end
