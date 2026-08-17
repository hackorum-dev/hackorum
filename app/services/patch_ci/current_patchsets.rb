module PatchCi
  # Keyed by topic id, decorated the way every CI table decorates its rows.
  # The topic index asks for a page of these at once, the thread page for
  # one - both go through BranchRows, so an icon and /ci/branches cannot end
  # up calling the same patchset two different things.
  class CurrentPatchsets
    def initialize(repo_state: PatchCiRepoState.current,
                   health: BranchHealth.new(repo_state: repo_state))
      @health = health
      @rows = BranchRows.new(repo_state: repo_state, health: health)
    end

    # topic_ids -> { topic_id => decorated PatchBranch }. A topic with no
    # patchset is absent rather than nil: callers render nothing for it, and an
    # absent key says that without a second emptiness check.
    def load(topic_ids)
      ids = Array(topic_ids).map(&:to_i).uniq
      return {} if ids.empty?

      # id DESC is a tiebreak, not the ordering that matters. The orchestrator
      # supersedes every older patchset, so a topic has exactly one current
      # row; a second one is a data bug, and taking the newest of them beats
      # raising in the middle of a page of 50 topics.
      relation = @health.with_reason(PatchBranch.current.where(topic_id: ids)).order(id: :desc)
      @rows.load(relation).group_by(&:topic_id).transform_values(&:first)
    end
  end
end
