module PatchCi
  # The whole pipeline, one cycle at a time. Every collaborator is injected;
  # bin/orchestrator does the wiring.
  class Orchestrator
    def initialize(client:, pusher:, guard:, apply_one:, result_refs:, pruner:,
                   repo:, master_sync:, slug_sync: nil,
                   budget: Config::BUDGET, max_pushes: nil, dry_run: false,
                   planner_factory: ->(state) { Planner.new(repo_state: state) })
      @client = client
      @pusher = pusher
      @guard = guard
      @apply_one = apply_one
      @result_refs = result_refs
      @pruner = pruner
      @repo = repo
      @master_sync = master_sync
      @slug_sync = slug_sync
      @budget = budget
      @max_pushes = max_pushes
      @dry_run = dry_run
      @planner_factory = planner_factory
      @total_pushed = 0
      @failed = 0
      @fetch_failed = false
      @mirror_error = nil
    end

    def cycle
      @failed = 0
      @first_error = nil
      # before anything that can fail on the network: an era image landing must
      # unstrand its rows even on a cycle where GitHub is down
      @era_skips_cleared = @dry_run ? 0 : EraSkipReset.new.call
      state = refresh_repo_state!
      runs = unrecorded(@client.runs)
      refs_ok = @result_refs.fetch!.success?
      ingested = {}
      stale_reason = "ref fetch failed"
      if refs_ok
        begin
          # payloads bounded by the current runs window, not by ref retention -
          # at 256KB/payload an unbounded read is a memory problem
          ingested = Ingestor.new(payloads: @result_refs.payloads(only: runs.map(&:id))).ingest(runs)
        rescue ResultRefs::ReadError => e
          # abnormal batch output is a failed read, not "no payloads": ingesting
          # then records infra_error for runs that reported fine
          refs_ok = false
          stale_reason = e.message
        end
      end
      # results stop landing on the site while this holds - never in silence
      warn "result refs stale (#{stale_reason}), no ingest this cycle" unless refs_ok
      # same guard as ingest: a broken ref fetch for 48h+ must not mass-mark
      # every waiting branch as infra_error; and a dry run must not write
      StuckRunMarker.new.call if refs_ok && !@dry_run
      pruned = (refs_ok && !@dry_run) ? @pruner.prune! : 0

      unseen = unseen_pushes
      in_flight = @client.in_flight_count + unseen
      free = [ [ @budget - in_flight, 0 ].max, remaining_pushes ].min

      pushed = 0
      if free.positive?
        # headroom: guard rejections and failed master probes consume items
        # without consuming slots
        items = @planner_factory.call(state).plan(limit: free * Config::PLAN_HEADROOM)
        items.each do |item|
          break if pushed >= free
          pushed += 1 if execute(item, state.master_sha)
        end
      end
      @total_pushed += pushed
      slugs_synced = sync_slugs
      warn "#{@failed} item(s) failed this cycle, first: #{@first_error}" if @failed.positive?

      DashboardBroadcast.refresh! unless @dry_run

      { in_flight: in_flight, unseen: unseen, free_slots: free, pushed: pushed, slugs_synced: slugs_synced, failed: @failed,
        pruned: pruned, era_skips_cleared: @era_skips_cleared, ingested: ingested,
        refs_stale: !refs_ok, fetch_failed: @fetch_failed, mirror_error: @mirror_error,
        error: nil }
    rescue GithubClient::Error => e
      # not knowing what is in flight must never be read as "nothing is".
      # the counters read zero even when the fetch and ingest above already
      # happened: the error path reports the cycle as a loss, on purpose
      { in_flight: nil, free_slots: 0, pushed: 0, slugs_synced: false, failed: 0, pruned: 0,
        era_skips_cleared: @era_skips_cleared, ingested: {}, refs_stale: true,
        fetch_failed: @fetch_failed, mirror_error: @mirror_error, error: e.message }
    end

    private

    # runs whose verdict is already stored together with their payload can
    # never change: promote only fires on a matching pushed_head_sha, and that
    # sha only moves on a new push, which means a new run id. Without this the
    # whole runs window gets cat-filed and re-parsed every 60s forever.
    # ingest_error rows are deliberately left in: their payload never made it
    # into the row, so a re-read is still worth something.
    def unrecorded(runs)
      return runs if runs.empty?

      recorded = PatchCiRun.terminal.where.not(payload: nil)
                           # qualified: the self-join below carries the column twice
                           .where("NOT (patch_ci_runs.payload ? 'ingest_error')")
                           # a stored verdict the branch never took is the
                           # self-healing path for a push interrupted between
                           # git push and the row update: the re-push is
                           # deterministic, so the same sha produces no new
                           # github run, and only a re-ingest can promote the
                           # verdict that is already sitting there.
                           # matched on the promoted run's sha, not its id: a
                           # re-run gives one sha two run ids, the branch can
                           # only promote one of them, and the other would
                           # else be re-read every cycle forever
                           .joins(:patch_branch)
                           .joins("LEFT JOIN patch_ci_runs promoted" \
                                  " ON promoted.id = patch_branches.latest_ci_run_id")
                           .where("promoted.head_sha IS NOT DISTINCT FROM patch_ci_runs.head_sha" \
                                  " OR patch_branches.pushed_head_sha IS DISTINCT FROM patch_ci_runs.head_sha")
                           .where(github_run_id: runs.map { |run| run.id.to_i })
                           .pluck(:github_run_id, :run_attempt).to_set
      runs.reject { |run| recorded.include?([ run.id.to_i, run.attempt.to_i ]) }
    end

    # a dry run against a warm DB touches neither the network nor the state
    # row: fetched_at is what the dashboard reads as "the orchestrator is
    # alive", and a dry run is not that. A first ever run still has to fetch,
    # or there is no master to plan against.
    def refresh_repo_state!
      @fetch_failed = false
      @mirror_error = nil
      existing = PatchCiRepoState.current
      return existing if @dry_run && existing

      result = @master_sync.call
      @fetch_failed = result.fetch_failed
      @mirror_error = result.mirror_error
      PatchCiRepoState.refresh!(master_sha: result.sha,
                                master_committed_at: @repo.commit_time(result.sha),
                                master_commit_height: @repo.commit_height(result.sha))
    end

    # pushed, but no run seen for it yet. github's own count cannot see these,
    # so on a silent event drop it stays low while pushes vanish
    def unseen_pushes
      PatchBranch.where(ci_status: "pushed_awaiting_ci")
                 .where(pushed_at: Config::UNSEEN_PUSH_HOURS.hours.ago..)
                 .count
    end

    def remaining_pushes
      @max_pushes ? [ @max_pushes - @total_pushed, 0 ].max : Float::INFINITY
    end

    # a sync error counts as a failure but must not stop the cycle
    def sync_slugs
      return false if @dry_run || @slug_sync.nil?

      result = @slug_sync.call
      if result.error
        @failed += 1
        @first_error ||= "slug sync: #{result.error}"
      end
      result.pushed
    rescue StandardError => e
      @failed += 1
      @first_error ||= "slug sync: #{e.class}: #{e.message}"
      false
    end

    def execute(item, master_sha)
      if @dry_run
        puts "[dry-run] #{item.kind} #{item.patch_branch&.branch_name || "message #{item.message.id}"}"
        return false
      end

      case item.kind
      when :backfill then guard_and_push(item.patch_branch)
      when :new_version then new_version(item, master_sha)
      when :rebase then rebase(item.patch_branch, master_sha)
      end
    rescue StandardError => e
      # one bad item must not kill the cycle, but it must not vanish either
      @failed += 1
      @first_error ||= "#{item.kind}: #{e.class}: #{e.message}"
      Rails.logger.error("orchestrator: #{item.kind} item failed: #{e.class}: #{e.message}")
      false
    end

    def new_version(item, master_sha)
      outcome, row = apply(item.message.id, master_sha: master_sha)
      return count_infra_failure(item.kind) if outcome == :infra_failed
      return false unless row&.persisted? && row.status == "applied"
      guard_and_push(row)
    end

    def rebase(row, master_sha)
      # master_only bypasses skippable? by design (a rebase input always looks
      # skippable), so one force: false ApplyOne serves both call shapes
      outcome, _row = apply(row.message_id, master_sha: master_sha, master_only: true)
      return count_infra_failure(:rebase) if outcome == :infra_failed
      return false unless outcome == :applied_on_master
      guard_and_push(row)
    end

    # An infra failure writes nothing to the row on purpose, so the cycle line is
    # the only place it can surface. Counted with the exceptions: a worktree that
    # has stopped applying anything must not read as a quiet cycle - unnoticed is
    # how one wedges for days.
    def count_infra_failure(kind)
      @failed += 1
      @first_error ||= "#{kind}: infra failure, nothing recorded on the row"
      false
    end

    # the [:error] seam: an exception out of an apply belongs on the row, and
    # persist_error is mode-aware, so a probe cannot rewrite a healthy branch
    def apply(message_id, **kwargs)
      @apply_one.call(message_id, **kwargs)
    rescue StandardError => e
      save_error = @apply_one.persist_error(e)
      Rails.logger.error("orchestrator: persist_error failed: #{save_error.message}") if save_error
      raise
    end

    def guard_and_push(row)
      # the row was read when the cycle planned, and an earlier item in the
      # same cycle may have superseded it since (or a probe moved its base).
      # The guard is only the last line of defense if it reads current columns.
      row.reload
      reason = @guard.check(row)
      if reason
        # a post-probe rejection still records ci_none: visible in wont_retry
        # beats silently stranded
        @pusher.skip(row, reason)
        return false
      end
      return false unless @pusher.push(row)

      supersede_older(row)
      true
    end

    # tied to the push, not to the tier that produced it: a new_version whose
    # push failed comes back through backfill later, and that retry has to
    # retire the old row too or the topic keeps two current rows forever.
    # Only the topic's newest patchset may displace the others, so an ordinary
    # backfill push of an old row changes nothing. Same ordering the planner
    # uses to pick the new_version message.
    def supersede_older(row)
      newest = Message.where(topic_id: row.topic_id, is_patch_submission: true)
                      .order(created_at: :desc, id: :desc).pick(:id)
      return unless newest && row.message_id == newest

      PatchBranch.where(topic_id: row.topic_id, superseded_by_id: nil, lineage_only: false)
                 .where.not(id: row.id).update_all(superseded_by_id: row.id)
    end
  end
end
