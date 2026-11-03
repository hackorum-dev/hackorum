module PatchCi
  # The corpus panel: today's patchsets laid out over PostgreSQL's history.
  # Not a replay of past states - nothing snapshots patch_branches over time.
  # Every aggregate goes through base_scope, and every one survives a nil
  # repo_state: without master's commit date there is no base age to measure.
  class CorpusStats
    # the histogram's bands, "unknown" always last. Public: the view renders
    # this same list and must not re-derive it on its own.
    BANDS = (Config::BASE_AGE_BUCKETS.map(&:first) + [ "unknown" ]).freeze

    def initialize(repo_state: PatchCiRepoState.current, active_only: false)
      @repo_state = repo_state
      @active_only = active_only
      @freshness = BaseFreshness.new(repo_state: repo_state)
      @health = BranchHealth.new(repo_state: repo_state)
      @check = MasterCheck.new(repo_state: repo_state)
    end

    # same five bands the pipeline panel stacks, plus the two states a branch can
    # be in that a run never sees: no verdict at all, and never applied
    OUTCOME_BANDS = %w[success cancelled tests_failed build_failed infra_error no_verdict never_applied].freeze

    OUTCOME_SQL = <<~SQL.freeze
      CASE
        WHEN patch_branches.status = 'failed' THEN 'never_applied'
        WHEN patch_branches.ci_status = 'success' THEN 'success'
        WHEN patch_branches.ci_status IN ('tests_failed', 'tests_timeout') THEN 'tests_failed'
        WHEN patch_branches.ci_status IN ('build_failed', 'build_timeout') THEN 'build_failed'
        WHEN patch_branches.ci_status = 'cancelled' THEN 'cancelled'
        WHEN patch_branches.ci_status = 'infra_error' THEN 'infra_error'
        ELSE 'no_verdict'
      END
    SQL

    TOP_LIST = 20

    SIZE_BUCKETS = [ [ "1", 1 ], [ "2-5", 5 ], [ "6-20", 20 ], [ "21-100", 100 ], [ ">100", nil ] ].freeze

    def all
      { headline: headline, base_age_distribution: base_age_distribution,
        freshness_tiers: freshness_tiers, master_check_tiers: master_check_tiers,
        outcome_by_base_year: outcome_by_base_year,
        success_rate_by_base_year: success_rate_by_base_year,
        apply_failures_by_base_year: apply_failures_by_base_year,
        build_cost_by_base_year: build_cost_by_base_year, per_major: per_major,
        top_conflict_files: top_conflict_files, coverage_by_era: coverage_by_era,
        wont_retry_reasons: wont_retry_reasons, size_vs_outcome: size_vs_outcome,
        patchsets_per_topic: patchsets_per_topic }
    end

    def outcome_by_base_year
      toggled_scope.group(base_year_sql, Arel.sql(OUTCOME_SQL)).count
           .map do |(year, band), count|
        { year: year&.to_i, band: band, count: count,
          band_index: OUTCOME_BANDS.index(band) || OUTCOME_BANDS.size }
      end.sort_by { |row| [ row[:year] || 0, row[:band_index] ] }
    end

    def success_rate_by_base_year
      verdicts = toggled_scope.where(ci_status: PatchCiRun::TERMINAL_STATUSES).group(base_year_sql).count
      wins = toggled_scope.where(ci_status: "success").group(base_year_sql).count
      verdicts.sort_by { |year, _| year.to_i }.map do |year, total|
        { year: year&.to_i, verdicts: total, rate: wins.fetch(year, 0).to_f / total }
      end
    end

    # failure_stage 'apply' means the patch would not apply even to its own
    # detected, contemporaneous base - a patch-extraction / base-detection
    # signal, not staleness. This does NOT measure how fast applyability
    # decays as master moves on: that one reads on_master, the same column
    # BranchHealth's needs_rebase bucket keys on. Every row carries it, the
    # historical backfill included - ApplyOne only falls back to a detected
    # base after master has failed, so on_master = false is itself the record
    # of a conflict. That series can be built; it is just not this one.
    def apply_failures_by_base_year
      totals = toggled_scope.group(base_year_sql).count
      stages = toggled_scope.failed.group(base_year_sql, :failure_stage).count
      totals.sort_by { |year, _| year.to_i }.map do |year, total|
        { year: year&.to_i, total: total,
          stages: PatchBranch::FAILURE_STAGES.index_with { |stage| stages.fetch([ year, stage ], 0) } }
      end
    end

    # both series always, off base_scope regardless of the active toggle: the
    # gap between them is the finding - how much of the stale mass is
    # abandoned threads rather than live work that drifted
    def base_age_distribution
      all_counts = base_scope.group(base_age_sql).count
      active_counts = active_scope.group(base_age_sql).count
      BANDS.flat_map do |band|
        [ { series: "all", band: band, count: all_counts.fetch(band, 0) },
          { series: "active", band: band, count: active_counts.fetch(band, 0) } ]
      end
    end

    # off BaseFreshness so this page and the /ci/branches base-age facet cannot
    # key the same rows differently
    def freshness_tiers
      @freshness.counts(base_scope)
    end

    # the pair to freshness_tiers: that one measures the base commit, this one
    # measures us. Different denominator on purpose - "are we keeping up" is a
    # question about the rows in front of you, so this one follows the toggle
    # while freshness_tiers stays corpus-wide.
    def master_check_tiers
      @check.counts(toggled_scope)
    end

    def headline
      patchsets = base_scope.count
      median_age = base_scope.pick(Arel.sql(median_age_sql)) if @repo_state
      { patchsets: patchsets,
        median_base_age_days: median_age,
        # nil, not 0.0, without a repo state: every base reads 'unknown' then,
        # and a 0% recent share would present as a finding instead of "can't measure"
        recent_rate: @repo_state ? rate(@freshness.filter(base_scope, [ "recent" ]).count, patchsets) : nil,
        verdict_rate: rate(base_scope.where(ci_status: PatchCiRun::TERMINAL_STATUSES).count, patchsets),
        # image_digest, not image_ref: the ghcr tag is one per topic and gets
        # overwritten by whichever run pushes last, so the tag overstates coverage
        image_rate: rate(base_scope.joins(:latest_ci_run).where.not(patch_ci_runs: { image_digest: nil }).count, patchsets) }
    end

    # a property of the base commit's era, not of our runners: pg10 built in ~95s
    # against 412 suites, pg20 in ~168s against 1013
    def build_cost_by_base_year
      toggled_scope.joins(:ci_runs).where(patch_ci_runs: { status: "success" })
           .group(base_year_sql)
           .pluck(base_year_sql,
                  median_of("patch_ci_runs.build_seconds"),
                  median_of("patch_ci_runs.test_seconds"),
                  median_of("patch_ci_runs.tests_total"))
           .map { |year, build, test, tests| { year: year&.to_i, build_median: build, test_median: test, tests_median: tests } }
           .sort_by { |row| row[:year] || 0 }
    end

    def per_major
      patchsets = toggled_scope.group(:pg_major).count
      images = toggled_scope.joins(:latest_ci_run).where.not(patch_ci_runs: { image_digest: nil }).group(:pg_major).count
      # base_scope no longer joins topics, so there is nothing to unscope; take the
      # ids off the relation rather than merging scopes
      runs = PatchCiRun.terminal.where(patch_branch_id: toggled_scope.select(:id))
                       .group(:"patch_ci_runs.pg_major")
                       .pluck(:"patch_ci_runs.pg_major",
                              Arel.sql("count(*)"),
                              Arel.sql("count(*) FILTER (WHERE patch_ci_runs.status = 'success')"),
                              median_of("patch_ci_runs.build_seconds"),
                              median_of("patch_ci_runs.test_seconds"),
                              median_of("patch_ci_runs.tests_total"))
                       .index_by(&:first)

      patchsets.keys.compact.sort.map do |major|
        _, total, wins, build, test, tests = runs.fetch(major, [ major, 0, 0, nil, nil, nil ])
        { pg_major: major, patchsets: patchsets.fetch(major, 0), runs: total,
          success_rate: rate(wins, total), build_median: build, test_median: test,
          tests_median: tests, images: images.fetch(major, 0),
          era: Eras.name_for(major), era_enabled: Eras.enabled?(major) }
      end
    end

    # 20 rows, unnested from apply-stage failures only: a rejected patch names
    # the files it collided on, so this is the corpus's actual conflict hotspot
    # list - conflicts counts every occurrence, branches counts distinct patchsets
    def top_conflict_files
      ids = toggled_scope.failed.where(failure_stage: "apply").select(:id)
      ActiveRecord::Base.connection.select_all(<<~SQL).to_a.map do |row|
        SELECT name, count(*) AS conflicts, count(DISTINCT id) AS branches
        FROM (
          SELECT unnest(conflict_files) AS name, id
          FROM patch_branches
          WHERE id IN (#{ids.to_sql})
        ) t
        GROUP BY name
        ORDER BY conflicts DESC, name ASC
        LIMIT #{TOP_LIST}
      SQL
        { name: row["name"], conflicts: row["conflicts"].to_i, branches: row["branches"].to_i }
      end
    end

    # active_scope, not toggled_scope: coverage of an abandoned thread is not a
    # gap, so this chart never varies with the active control
    def coverage_by_era
      counts = active_scope.group(:pg_major, Arel.sql(verdict_sql)).count
      by_era = counts.each_with_object({}) do |((major, has_verdict), count), acc|
        era = Eras.name_for(major) || "unknown"
        acc[era] ||= { era: era, with_verdict: 0, without_verdict: 0,
                       era_enabled: major ? Eras.enabled?(major) : false }
        acc[era][has_verdict ? :with_verdict : :without_verdict] += count
      end
      by_era.values.sort_by { |row| row[:era] }
    end

    # straight off BranchHealth: the dashboard panel shows the top three of this
    # same breakdown, and two owners of one number is how they drift
    def wont_retry_reasons
      @health.wont_retry_breakdown
    end

    # answers something nothing else can: whether big patchsets fail CI more, or
    # only fail to apply more
    def size_vs_outcome
      toggled_scope.joins(<<~SQL)
        LEFT JOIN (
          SELECT message_id, count(*) AS files
          FROM patch_submission_files
          GROUP BY message_id
        ) sf ON sf.message_id = patch_branches.message_id
      SQL
           .group(size_bucket_sql, Arel.sql(OUTCOME_SQL)).count
           .map do |(bucket, band), count|
        { bucket: bucket, band: band, count: count,
          band_index: OUTCOME_BANDS.index(band) || OUTCOME_BANDS.size }
      end.sort_by { |row| [ size_buckets.index(row[:bucket]) || size_buckets.size, row[:band_index] ] }
    end

    # every patchset of a topic, superseded included - those rows are the
    # version history of the topic, so this deliberately does not use
    # PatchBranch.current the way every other aggregate here does
    def patchsets_per_topic
      ActiveRecord::Base.connection.select_all(<<~SQL).to_a.map do |row|
        SELECT versions, committed, count(*) AS topics
        FROM (
          SELECT pb.topic_id,
                 count(*) AS versions,
                 EXISTS (SELECT 1 FROM commit_topics ct
                          WHERE ct.topic_id = pb.topic_id AND ct.source = 'trailer') AS committed
          FROM patch_branches pb
          WHERE NOT pb.lineage_only
          GROUP BY pb.topic_id
        ) t
        GROUP BY versions, committed
        ORDER BY versions
      SQL
        { versions: row["versions"].to_i,
          series: ActiveModel::Type::Boolean.new.cast(row["committed"]) ? "committed" : "not committed",
          count: row["topics"].to_i }
      end
    end

    private

    def verdict_sql
      @verdict_sql ||= ActiveRecord::Base.sanitize_sql_array(
        [ "patch_branches.ci_status IN (?)", PatchCiRun::TERMINAL_STATUSES ]
      )
    end

    # no topics join here - base_scope stays topic-free so every caller from
    # headline through per_major pays for the join only when active_scope
    # actually needs it (active_only toggle)
    def base_scope
      PatchBranch.current
    end

    def active_scope
      base_scope.joins(:topic).where(topics: { merged_into_topic_id: nil })
                .where("topics.last_message_at >= ?", Config::ACTIVE_THREAD_DAYS.days.ago)
    end

    # what an aggregate reads when it should follow the discussions control.
    # Several deliberately do not - headline and freshness_tiers stay
    # corpus-wide, base_age_distribution plots both scopes side by side,
    # coverage_by_era is active-only - and each says why where it is defined.
    def toggled_scope
      @active_only ? active_scope : base_scope
    end

    def median_of(column)
      Arel.sql("percentile_cont(0.5) WITHIN GROUP (ORDER BY #{column})")
    end

    # a year, not a date: the corpus axis is 2012 to today and a temporal scale
    # with fourteen year ticks reads worse than an ordinal one
    def base_year_sql
      @base_year_sql ||= Arel.sql("date_part('year', patch_branches.base_committed_at)")
    end

    def base_age_sql
      # ::text cast: postgres rejects a bare string constant in GROUP BY
      # ("non-integer constant in GROUP BY"), casting makes it a real expression
      @base_age_sql ||= @repo_state ? dated_base_age_sql : Arel.sql("'unknown'::text")
    end

    # strict >: the bucket's own day count is its upper, exclusive bound - a
    # base exactly N days old belongs to the next band up, not this one
    def dated_base_age_sql
      BucketCase.sql(Config::BASE_AGE_BUCKETS, expr: "patch_branches.base_committed_at", operator: ">",
                      bound_sql: ->(days) { ActiveRecord::Base.connection.quote(@repo_state.master_committed_at - days.days) },
                      null_check: "patch_branches.base_committed_at IS NULL")
    end

    def median_age_sql
      ActiveRecord::Base.sanitize_sql_array(
        [ "percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch from (?::timestamp - patch_branches.base_committed_at)) / 86400)",
          @repo_state.master_committed_at ]
      )
    end

    def rate(part, total)
      return nil if total.to_i.zero?
      part.to_f / total
    end

    def size_buckets
      @size_buckets ||= SIZE_BUCKETS.map(&:first) + [ "unknown" ]
    end

    # a patchset with no patch_submission_files rows is one we never extracted
    # paths for - not a one-file patch
    def size_bucket_sql
      @size_bucket_sql ||= BucketCase.sql(SIZE_BUCKETS, expr: "sf.files", operator: "<=",
                                          bound_sql: ->(bound) { bound.to_i.to_s },
                                          null_check: "sf.files IS NULL")
    end
  end
end
