module PatchCi
  # every tunable in one place (script entry points default to nil at
  # optparse time and fill in from here after rails loads)
  module Config
    SLUG_SYNC_BRANCH = "hackorum-slugs" # fork branch whose workflow retags slug images
    SLUG_RESYNC_HOURS = 24      # full retag at least this often
    BUDGET = 30                 # queued+running target on github
    IN_PROGRESS_LIST = 40
    UP_NEXT_LIST = 30
    RECENT_LIST = 50
    BRANCHES_PAGE = 100         # /ci/branches page size
    REBASE_AFTER_DAYS = 30      # base this far behind master -> stop retrying
    ANCIENT_AFTER_DAYS = 365    # base older than a major release cycle; keep above REBASE_AFTER_DAYS
    # only CorpusStats reads this, for the /ci/stats "active threads" toggle.
    # Not a scheduling input: whether a patch applies on master has nothing to
    # do with whether anyone is still discussing it.
    ACTIVE_THREAD_DAYS = 30     # thread with newer messages counts as active
    STUCK_RUN_HOURS = 48        # pushed but no verdict -> infra_error
    # github drops a job queued this long, so an older in-flight run is a ghost
    # the API keeps listing - it must not hold a budget slot forever
    GHOST_RUN_HOURS = 24
    # a push github has not turned into a run yet still holds a slot this long.
    # Without it a silent event drop (actions disabled, incident) reads as an
    # empty budget and the whole queue gets pushed into nothing.
    UNSEEN_PUSH_HOURS = 2
    PUSH_RETRY_MINUTES = 30     # backoff before retrying a push_failed row
    # how often a row is re-probed against master. The probe is cheap, the push
    # it triggers is not, so this is the cadence of the whole rebase tier.
    MASTER_CHECK_AFTER_HOURS = 24
    # when the UI calls a row overdue. Above MASTER_CHECK_AFTER_HOURS on
    # purpose: a row waiting its turn in a normal sweep is not a problem.
    MASTER_CHECK_WARN_HOURS = 26
    # items planned per free CI slot. Guard rejections and failed master probes
    # consume items without consuming slots, so the planner is always asked for
    # more than the budget can push.
    PLAN_HEADROOM = 3
    RESULT_REF_KEEP_DAYS = 14   # refs/hackorum-ci retention after ingest
    # backstop on the cached whole-table aggregates: the cache key carries the
    # repo state's fetched_at, so a live orchestrator turns them over sooner
    AGGREGATE_TTL = 1.minute
    WORK_FROM = Time.zone.parse("2017-01-01").freeze # commit status floor, same as backfill

    # /ci/stats only. A bucket below this many terminal runs gets its rate drawn
    # hollow: a success rate over four runs is noise, not a trend.
    SPARSE_BUCKET_RUNS = 5
    # push lag = run.queued_at - message.created_at. Upper bound in days, nil is
    # the open-ended tail; order is the display order.
    PUSH_LAG_BUCKETS = [ [ "same day", 1 ], [ "days", 7 ], [ "weeks", 30 ],
                         [ "months", 365 ], [ "older", nil ] ].freeze
    # base age = master_committed_at - base_committed_at, same shape
    BASE_AGE_BUCKETS = [ [ "<1d", 1 ], [ "1-7d", 7 ], [ "7-30d", 30 ],
                         [ "30-90d", 90 ], [ "90d-1y", 365 ], [ "1-2y", 730 ],
                         [ "2-5y", 1825 ], [ ">5y", nil ] ].freeze

    # the fork CI pushes to. Views build github.com URLs off this;
    # bin/orchestrator takes it as its default.
    GITHUB_REPO = "hackorum-dev/postgres"
  end
end
