module PatchCi
  # Every patchset of one topic with its runs - the CI history page's only
  # query object. Deliberately not PatchBranch.current: the superseded rows
  # are the history.
  class TopicHistory
    def initialize(topic:, repo_state: PatchCiRepoState.current,
                   health: BranchHealth.new(repo_state: repo_state),
                   freshness: BaseFreshness.new(repo_state: repo_state))
      @topic = topic
      @health = health
      @freshness = freshness
    end

    def patchsets
      load!
      @patchsets
    end

    def runs_for(row)
      load!
      @runs_by_branch.fetch(row.id, [])
    end

    def current
      patchsets.find { |row| row.superseded_by_id.nil? }
    end

    # the image tag is per topic and overwritten by every run in it, so at most
    # one run's tag is still live - and it need not belong to the current row.
    # last to finish pushing wins the tag, not run-id order: a re-run carries a
    # higher attempt against an older run id, so run-id order would hand the
    # tag to whichever run merely started later.
    # defined?, not ||=: nil is the answer for a topic that never built one,
    # and this is asked once per rendered run row
    #
    # TopicStatus#image_run picks the same run for the thread page, in SQL
    # instead of Ruby - it wants a single row and this page already has every
    # run loaded, so neither should switch to the other's approach. Deliberate
    # duplicate: a change to the ordering rule has to land in both.
    def live_image_run_id
      return @live_image_run_id if defined?(@live_image_run_id)
      load!
      @live_image_run_id = @runs_by_branch.values.flatten
                                          .select { |run| run.image_ref.present? }
                                          .max_by { |run| [ run.completed_at || run.started_at || run.queued_at || run.created_at, run.github_run_id ] }&.id
    end

    private

    # one pass: rows first, then their runs, then the summaries. Not memoized
    # per method - runs_for is called once per rendered row and must not
    # re-decide anything.
    def load!
      return if defined?(@patchsets)
      rows = decorate(base_scope).to_a
      @runs_by_branch = load_runs(rows.map(&:id))
      rows.each do |row|
        row.latest_run_summary =
          @runs_by_branch.fetch(row.id, []).find { |run| run.id == row.latest_ci_run_id }
      end
      @patchsets = rows
    end

    # same ordering Orchestrator#supersede_older uses to pick the newest
    # patchset, so the page and the orchestrator cannot disagree about which
    # one is current. preload, not joins-and-reuse: the select carries alias
    # columns, and the message is needed whole for the thread anchor.
    def base_scope
      PatchBranch.where(topic_id: @topic.id)
                 .joins(:message)
                 .preload(:message)
                 .order(Arel.sql("messages.created_at DESC, messages.id DESC"))
    end

    def decorate(relation)
      @freshness.with_tier(@health.with_bucket(relation))
    end

    # payload is up to 256KB of json per row and never belongs in a list, but
    # ccache and the ingest error live nowhere else - so extract those three
    # scalars server-side. As text, never cast: payload is hostile input and a
    # non-numeric ccache would take the whole query down as a cast error.
    def load_runs(ids)
      return {} if ids.empty?
      PatchCiRun.where(patch_branch_id: ids)
                .select(*PatchCiRun.list_columns,
                        Arel.sql("patch_ci_runs.payload #>> '{ccache,hit}' AS ccache_hit"),
                        Arel.sql("patch_ci_runs.payload #>> '{ccache,miss}' AS ccache_miss"),
                        Arel.sql("patch_ci_runs.payload ->> 'ingest_error' AS ingest_error"))
                .order(Arel.sql("COALESCE(completed_at, started_at, queued_at, created_at) DESC, github_run_id DESC, run_attempt DESC"))
                .readonly
                .group_by(&:patch_branch_id)
    end
  end
end
