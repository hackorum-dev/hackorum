module PatchCi
  # One topic's CI facts for the thread page: its current patchset, and the run
  # that still owns the topic's ghcr tag. The tag is :t<topic_id> and every run
  # in the topic overwrites it, so the run that owns it need not belong to the
  # patchset being discussed - which is the whole reason this class exists.
  class TopicStatus
    # last to finish pushing wins the tag, not run-id order: a re-run carries a
    # higher attempt against an older run id, so ordering by id would hand the
    # tag to whichever run merely started later.
    #
    # TopicHistory#live_image_run_id picks the same run, in Ruby off rows it
    # already holds - that page loads every run for the topic anyway, this one
    # wants a single row and asks the database instead. Deliberate duplicate,
    # not an oversight: a change to the ordering rule has to land in both.
    # image_ref filter here is [nil, ""], there it is .present? (also excludes
    # whitespace-only) - the two agree on every value the ingestor can
    # produce, so the gap is not load-bearing.
    IMAGE_RUN_ORDER = <<~SQL.squish.freeze
      COALESCE(patch_ci_runs.completed_at, patch_ci_runs.started_at,
               patch_ci_runs.queued_at, patch_ci_runs.created_at) DESC,
      patch_ci_runs.github_run_id DESC
    SQL

    # UNSET, not a plain nil default: nil is a value a caller can hand in on
    # purpose (CurrentPatchsets copes with no repo state), and the ivar must
    # stay unset until then so the lazy reader below can tell the two apart.
    UNSET = Object.new.freeze

    def initialize(topic:, repo_state: UNSET)
      @topic = topic
      @repo_state = repo_state unless repo_state.equal?(UNSET)
    end

    # thread pages are the hottest page in the app, and most threads have no
    # patchset - row is the only caller, so this must not query until
    # something actually needs it.
    # defined?, not ||=: PatchCiRepoState.current is a legit nil with no repo
    # state row yet, and ||= would re-query every time that is true.
    def repo_state
      return @repo_state if defined?(@repo_state)
      @repo_state = PatchCiRepoState.current
    end

    # defined?, not ||=: nil is the answer for a topic with no current patchset.
    def row
      return @row if defined?(@row)
      @row = CurrentPatchsets.new(repo_state: repo_state).load([ @topic.id ])[@topic.id]
    end

    def present?
      row.present?
    end

    # defined?, not ||=: nil is the answer for a topic that never built one.
    def image_run
      return @image_run if defined?(@image_run)
      @image_run = PatchCiRun.joins(:patch_branch)
                             .where(patch_branches: { topic_id: @topic.id })
                             .where.not(image_ref: [ nil, "" ])
                             .select(*PatchCiRun.list_columns)
                             .order(Arel.sql(IMAGE_RUN_ORDER))
                             .readonly
                             .first
    end

    # the patchset that built the live image. The banner names it so a reader
    # can tell whether the image they are about to pull is the patch under
    # discussion. A second query, not a reuse of image_run's join - that join
    # filters by branch without selecting any branch column, so there is
    # nothing there to eager_load onto. Message preloaded - the banner reads
    # its number and date.
    def image_branch
      return @image_branch if defined?(@image_branch)
      @image_branch = image_run && PatchBranch.preload(:message).find_by(id: image_run.patch_branch_id)
    end

    # row.present? is not mere nil-safety: it is the case of an image run with
    # no current patchset at all, and false is the right answer there too.
    def image_current?
      image_run.present? && row.present? && image_run.patch_branch_id == row.id
    end
  end
end
