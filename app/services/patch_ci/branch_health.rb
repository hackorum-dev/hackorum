module PatchCi
  # One CASE expression, three consumers: dashboard counts, per-row labels,
  # /ci/branches filters. Keeping it in SQL keeps the three in agreement.
  #
  # The bucket is the last known apply outcome: not how recently we looked,
  # and not what happens next. MasterCheck owns recency, Planner owns the
  # queue - a row Planner is throttling still shows its last outcome here.
  #
  # Deliberate divergence from Planner (do not "fix" it, the two read
  # different questions): every failed row reads never_applied whatever its
  # stage, while Planner still retries never-pushed apply and base_detection
  # failures. The count and the rebase tier overlap on purpose.
  class BranchHealth
    BUCKETS = %w[applies needs_rebase awaiting_ci wont_retry never_applied].freeze

    def initialize(repo_state: PatchCiRepoState.current)
      @repo_state = repo_state
    end

    # the counts every page shows. One owner, so the dashboard and /ci/branches
    # cannot key the same numbers differently and drift apart. Keyed on the repo
    # state because these are whole-table aggregates recomputed per fetch cycle.
    def cached_counts
      @cached_counts ||= Rails.cache.fetch([ "ci-health-counts", @repo_state&.fetched_at ],
                                           expires_in: Config::AGGREGATE_TTL) { counts }
    end

    # memoized: one instance = one request = one consistent snapshot (a
    # second call must not recompute cutoffs and disagree with the first)
    def counts
      @counts ||= base_scope.group(Arel.sql(bucket_sql)).count
                             .transform_keys(&:to_s)
                             .then { |h| BUCKETS.index_with { |b| h.fetch(b, 0) } }
    end

    def scope_for(bucket)
      bucket = bucket.to_s
      raise ArgumentError, "unknown bucket: #{bucket.inspect}" unless BUCKETS.include?(bucket)
      base_scope.where("#{bucket_sql} = ?", bucket)
    end

    # no production caller: this is the oracle ~18 with_bucket/scope_for
    # examples check the CASE against one row at a time. Do not delete it as
    # dead code - the spec file goes with it.
    def bucket_for(row)
      base_scope.where(id: row.id).pick(Arel.sql(bucket_sql))
    end

    # several buckets at once, on a caller's relation - scope_for covers the
    # single-bucket case off base_scope. Mirrors BaseFreshness#filter.
    def filter(relation, buckets)
      buckets = Array(buckets).map(&:to_s) & BUCKETS
      return relation if buckets.empty?
      relation.joins(:topic, :message).where("#{bucket_sql} IN (?)", buckets)
    end

    # Narrows a relation - needs_rebase in practice - to the rows whose failure
    # was reached against the master we have now. master_apply_sha is what makes
    # that answerable at all: the same error against last week's master is a
    # stale answer waiting for its re-probe, and master moves several times a
    # day, so most of the bucket is that. Rows that never reached master carry no
    # sha and are excluded, which is the point.
    def failing_on_current_master(relation)
      return relation.none unless @repo_state
      relation.where(master_apply_sha: @repo_state.master_sha)
    end

    def wont_retry_breakdown
      scope_for("wont_retry")
        .group(Arel.sql(wont_retry_reason_sql)).count
        .sort_by { |_, c| -c }.to_h
    end

    # rows plus a health_bucket column, in one query - every list that renders
    # the shared table goes through here (/ci/branches and both /ci dashboard
    # sections, via BranchRows), so N rows do not cost N bucket_for round trips
    def with_bucket(relation = base_scope)
      # bucket_sql references topics and messages; joins is deduped when
      # already present
      relation.joins(:topic, :message)
              .select(PatchBranch.arel_table[Arel.star], Arel.sql("(#{bucket_sql}) AS health_bucket"))
    end

    # rows plus why a retired row retired. Deliberately not folded into
    # with_bucket: the three pages that render the shared table never read it,
    # so they should not pay for a second CASE. The CASE resolves for every row
    # though, ELSE and all - off the wont_retry bucket it would call a healthy
    # row "base too old". Naming the column for the bucket it is true of makes
    # that visibly wrong at the call site instead of silently wrong.
    def with_reason(relation = base_scope)
      relation.joins(:topic, :message)
              .select(PatchBranch.arel_table[Arel.star],
                      Arel.sql("(#{wont_retry_reason_sql}) AS wont_retry_reason"))
    end

    private

    # memoized alongside counts/bucket_for/scope_for for the same reason:
    # one instance, one set of cutoffs
    def bucket_sql
      @bucket_sql ||= begin
        # same boundary BaseFreshness draws between recent and stale, read as
        # a yes/no instead of a tier. Without a repo state there is nothing to
        # measure against, so WORK_FROM is the floor - a pre-2017 base still
        # reads retired. BaseFreshness falls back to 'unknown' instead; both
        # are deliberate and spec-pinned.
        stale_cutoff = @repo_state ? @repo_state.master_committed_at - Config::REBASE_AFTER_DAYS.days : Config::WORK_FROM
        # The bucket is the last master attempt's answer, and only an attempt
        # counts as one. Comparing base_sha against the master tip is not it:
        # master moves several times a day, so a row whose base is not the tip is
        # the normal state of a healthy patchset, not a verdict on it.
        #
        # Both columns are needed. on_master carries the rows from before
        # master_apply_error existed - ApplyOne only reaches the detected-base
        # path after master has already failed, so an applied row off master
        # conflicted whatever the error column says. And master_apply_error
        # carries the rows that applied once and have failed since: nothing moves
        # on_master back, so reading it alone was how a row that stopped applying
        # weeks ago kept claiming it still does. ApplyOne keeps the column clean
        # for this - an infra failure or a crash writes no verdict there - so a
        # set error always means "we tried master and could not get there".
        #
        # The arms are ordered and the order is the rule. Retirement outranks
        # outcome, so an on_master row whose base has aged out reads wont_retry
        # rather than applies. awaiting_ci outranks both, matching Planner's
        # in-flight exclusion - a force-push would burn the running CI slot.
        # And wont_retry comes out of two arms meaning different things,
        # terminal-by-nature and retired-by-age; wont_retry_reason_sql is where
        # they are told apart.
        #
        # The committed arm is CommitCutoff's, not a local copy, and it is a
        # question about the patchset rather than the thread: a fix mailed after
        # the commit is live work, and Planner keeps scheduling it. The two
        # still disagree about failed rows, on purpose - see the note above.
        ActiveRecord::Base.sanitize_sql_array(
          [ <<~SQL, stale_cutoff: stale_cutoff ])
          CASE
            WHEN patch_branches.ci_status = 'ci_none'
              OR (#{CommitCutoff::SUPERSEDED})
              OR topics.merged_into_topic_id IS NOT NULL
              THEN 'wont_retry'
            WHEN patch_branches.status = 'failed' THEN 'never_applied'
            WHEN patch_branches.pushed_at IS NULL THEN 'awaiting_ci'
            WHEN patch_branches.ci_status IN (#{in_flight_list})
              THEN 'awaiting_ci'
            WHEN patch_branches.base_committed_at IS NOT NULL
              AND patch_branches.base_committed_at < :stale_cutoff THEN 'wont_retry'
            -- the IS NOT NULL above only spells out what the comparison
            -- already does; the one below is load bearing. No base date means
            -- the age is unjudgeable, so the row falls to needs_rebase and
            -- stays retryable rather than claiming to apply. Do not collapse
            -- the two into one shape.
            WHEN patch_branches.on_master
              AND patch_branches.master_apply_error IS NULL
              AND patch_branches.base_committed_at IS NOT NULL THEN 'applies'
            ELSE 'needs_rebase'
          END
        SQL
      end
    end

    def base_scope
      PatchBranch.current.joins(:topic, :message)
    end

    # literals from a frozen constant, never user input
    def in_flight_list
      PatchCiRun::IN_FLIGHT_BRANCH_STATUSES.map { |status| "'#{status}'" }.join(", ")
    end

    # the ELSE is the retired-by-age arm by elimination, not a catch-all: an
    # aged-out base is the only other thing bucket_sql sends to wont_retry. A
    # fifth arm there needs one here, or it renders as "base too old".
    def wont_retry_reason_sql
      <<~SQL
        CASE
          WHEN patch_branches.ci_status = 'ci_none' THEN coalesce(patch_branches.ci_skip_reason, 'ci_none')
          WHEN #{CommitCutoff::SUPERSEDED} THEN 'committed'
          WHEN topics.merged_into_topic_id IS NOT NULL THEN 'merged thread'
          ELSE 'base too old'
        END
      SQL
    end
  end
end
