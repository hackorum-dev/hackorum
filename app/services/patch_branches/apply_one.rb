require "digest"
require "tmpdir"

module PatchBranches
  # One message end to end: extract, try master, detect base, apply, save.
  # The single writer of patch_branches rows (Runner fans out over this).
  class ApplyOne
    PROBE_PREFIX = "rebase_probe_".freeze

    # exposed for callers that need the partial context of a failed call
    # (Runner turns it into an "error" row + counters)
    attr_reader :record, :message, :save_error

    def initialize(repo:, worktree:, force: false, lineage_only: false)
      @repo = repo
      @worktree = worktree
      @force = force
      @lineage_only = lineage_only
      @era = PatchCi::EraDetector.new(repo)
    end

    # -> [ outcome_symbol, PatchBranch or nil ]
    #
    # master_only probes master and nothing else: on success the row and the
    # branch move to the new master, on any failure only the master-attempt
    # columns are touched, so a probe can never damage a working branch or
    # hide its row from the planner.
    def call(message_id, master_sha:, master_only: false)
      reset_state
      @master_only = master_only
      @message = Message.includes(:attachments, :topic).find(message_id)
      @branch_name = "t#{@message.topic_id}_#{@message.topic.chronological_index_of(@message)}"
      @record = PatchBranch.find_or_initialize_by(message_id: @message.id)

      # a lineage run never takes a row CI already owns: the flag only moves
      # one way, lineage -> CI
      return [ :skipped, @record ] if @lineage_only && @record.persisted? && !@record.lineage_only

      if master_only
        # no row means no branch to rebase; building one is the normal path's
        # job, and a probe must never write a first version of a row - and a
        # lineage row is not a branch CI owns, so there is nothing to rebase
        # either
        return [ :skipped, @record ] unless @record.persisted? && !@record.lineage_only
        # already sitting on this master: re-applying would only churn the ref
        if @record.status == "applied" && @record.base_sha == master_sha
          return [ :already_current, @record ]
        end
      end

      Dir.mktmpdir("patchset") do |dir|
        files = PatchsetExtractor.new(@message).extract(dir)
        content_hash = Digest::SHA256.hexdigest(files.map { |f| File.binread(f) }.join)

        # a master probe is an explicit "try it again now", and its input
        # always looks skippable (applied row, unchanged patchset)
        return [ :skipped, @record ] if !master_only && skippable?(content_hash)

        applier = Applier.new(@worktree)
        return apply_master_only(applier, files, master_sha, content_hash) if master_only

        apply_with_base_detection(applier, files, master_sha, content_hash)
      end
    rescue PatchsetExtractor::Error => e
      save_failure(failure_stage: "extract", failure_reason: e.message)
      [ :extract_failed, @record ]
    end

    # Writes the "error" row for an exception raised out of #call (a probe only
    # gets its master-attempt columns touched). Returns the exception the save
    # itself died with, nil when the row was written.
    def persist_error(e)
      return nil unless @record && @message && @branch_name

      save_failure(failure_stage: "error",
                   failure_reason: clip("#{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}"))
      @save_error
    end

    private

    def reset_state
      @message = nil
      @branch_name = nil
      @record = nil
      @save_error = nil
      @master_only = false
    end

    def apply_with_base_detection(applier, files, master_sha, content_hash)
      master_result = applier.apply(master_sha, files, @branch_name,
                                    committed_at: @message.created_at)
      if master_result.success?
        save(status: "applied", base_sha: master_sha, on_master: true,
             base_source: "master", content_hash: content_hash,
             master_attempt: applied_attempt(master_sha))
        return [ :applied_on_master, @record ]
      end

      # git never looked at the patch, so master did not fail - handing that to
      # base detection would build the row on an older base, or fail it at
      # "apply", over a problem the patchset has no part in. Nothing is written:
      # the next cycle finds the row exactly as it was.
      return [ :infra_failed, @record ] if master_result.infra?

      # applied and changed nothing: not a conflict, so base detection has no
      # part to play - and an older base is not the answer either. On the base
      # where it was submitted an upstreamed patch does still apply, and testing
      # that tells us nothing about the patch we were asked about.
      return save_empty(master_result) if master_result.empty_result?

      detection = BaseCommitDetector
        .new(@repo, files, submission_date: @message.created_at)
        .detect

      if detection.nil?
        save(status: "failed", failure_stage: "base_detection",
             failure_reason: clip(master_result.output),
             conflict_files: master_result.conflict_files,
             content_hash: content_hash,
             master_attempt: failed_attempt(master_sha, master_result))
        return [ :no_base, @record ]
      end

      result = detection.sha == master_sha ? master_result
                                           : applier.apply(detection.sha, files, @branch_name,
                                                           committed_at: @message.created_at)

      if result.success?
        save(status: "applied", base_sha: detection.sha, on_master: false,
             base_source: detection.source, content_hash: content_hash,
             master_attempt: failed_attempt(master_sha, master_result))
        [ :applied_on_base, @record ]
      elsif result.empty_result?
        save_empty(result)
      else
        save(status: "failed", failure_stage: "apply", base_sha: detection.sha,
             base_source: detection.source, failure_reason: clip(result.output),
             conflict_files: result.conflict_files,
             content_hash: content_hash,
             master_attempt: failed_attempt(master_sha, master_result))
        [ :apply_failed, @record ]
      end
    end

    # Applier deletes the branch it was handed when an apply fails, so the
    # probe gets a scratch name and the real branch only moves on success.
    def apply_master_only(applier, files, master_sha, content_hash)
      probe = "#{PROBE_PREFIX}#{@branch_name}"
      result = applier.apply(master_sha, files, probe, committed_at: @message.created_at)

      unless result.success?
        # not even the probe timestamp: it is the rebase tier's throttle, so
        # bumping it for a failure that never tested the patch parks a healthy
        # row for a day and records a conflict it never had
        return [ :infra_failed, @record ] if result.infra?

        # The one failure a probe does write status for. The rule it breaks -
        # never retire a healthy pushed branch from a probe - is there because a
        # conflict is transient and a rebase can undo it. An empty result is not:
        # the branch out there holds an empty commit, and leaving the row applied
        # keeps a CI verdict on the page that is about nothing.
        return save_empty(result) if result.empty_result?

        # no attempted_at bump on purpose: the row's own base was not retried,
        # only master was, and that has its own timestamp
        touch_master_apply_only(failed_attempt(master_sha, result))
        return [ :master_apply_failed, @record ]
      end

      # branch first, row second - not atomic. A crash in between leaves a
      # branch ahead of a stale row; last_master_apply_at is still old, so the
      # next probe picks the row up again and repairs both.
      @worktree.run!("branch", "-f", @branch_name, probe)
      @worktree.run("branch", "-D", probe)
      save(status: "applied", base_sha: master_sha, on_master: true,
           base_source: "master", content_hash: content_hash,
           master_attempt: applied_attempt(master_sha))
      [ :applied_on_master, @record ]
    end

    def skippable?(content_hash)
      # a lineage row is not CI's: the normal path has to apply it again and
      # own it before anything may push it, so "already applied" does not count
      return false if @record.lineage_only && !@lineage_only

      !@force && @record.persisted? &&
        @record.status == "applied" && @record.patch_content_hash == content_hash &&
        @record.base_committed_at.present?
    end

    # A probe never writes status/failure_*: those move the row out of every
    # planner tier, so a failed probe would retire a healthy pushed branch.
    # What keeps it in the rebase tier is its base_sha still differing from
    # master; the master_apply_* columns only record what the last probe found.
    # keep_base: extract and error fire before anything looks at a base, so
    # save's nil defaults would destroy columns the failure has no bearing on -
    # and a row that once applied would become indistinguishable from one that
    # never had a base. base_detection is different: it did look, and found
    # nothing for this patchset, so there the nils are the answer.
    def save_failure(failure_stage:, failure_reason:)
      return touch_probe_stamp_only if @master_only

      tolerantly do
        save(status: "failed", failure_stage: failure_stage, failure_reason: failure_reason,
             keep_base: true)
      end
    end

    # keep_base: the branch that is already out there was built on that base, and
    # the row is the only record of it. No master_attempt either - the apply did
    # reach master, but "changed nothing" is a verdict on the patchset, not on
    # whether it conflicts, and master_apply_error is read as the latter.
    def save_empty(result)
      tolerantly do
        save(status: "failed", failure_stage: "empty", failure_reason: clip(result.output),
             keep_base: true)
      end
      [ :empty_patchset, @record ]
    end

    def touch_master_apply_only(attempt)
      tolerantly do
        touch_master_apply(attempt)
        @record.save!
      end
    end

    # A probe that died before it got to master - extraction failed, or the call
    # blew up - found out nothing about master, so the verdict columns keep the
    # answer the last real attempt gave. The stamp still moves: it is the
    # throttle, and a patchset that cannot be extracted would otherwise be
    # retried every cycle forever.
    def touch_probe_stamp_only
      tolerantly do
        @record.assign_attributes(last_master_apply_at: Time.current)
        @record.save!
      end
    end

    # a save on a rescue path (e.g. branch_name unique collision, or a row that
    # never made it to valid) must not kill the caller; the exception is
    # reported through save_error instead
    def tolerantly
      yield
      nil
    rescue => e
      @save_error = e
    end

    def save(status:, base_sha: nil, on_master: false, base_source: nil,
             failure_stage: nil, failure_reason: nil, conflict_files: [],
             content_hash: nil, master_attempt: :unset, keep_base: false)
      now = Time.current
      @record.assign_attributes(
        topic_id: @message.topic_id,
        branch_name: @branch_name,
        status: status,
        failure_stage: failure_stage,
        failure_reason: failure_reason,
        conflict_files: conflict_files || [],
        patch_content_hash: content_hash,
        attempted_at: now,
        lineage_only: @lineage_only
      )
      @record.assign_attributes(base_columns(base_sha, on_master, base_source)) unless keep_base
      touch_master_apply(master_attempt, now: now) unless master_attempt == :unset
      first_real_write = !@lineage_only && (@record.new_record? || @record.lineage_only_was)
      @record.save!
      FeedEvents::Recorder.branch_created(@record) if first_real_write
    end

    # the six columns that only mean anything together: all derived from
    # base_sha, so they are written as one group or not at all
    def base_columns(base_sha, on_master, base_source)
      committed_at = base_sha && @repo.commit_time(base_sha)
      Rails.logger.warn("patch_branches meta lookup failed for #{@branch_name} base #{base_sha}") if base_sha && !committed_at
      { base_sha: base_sha, on_master: on_master, base_source: base_source,
        base_committed_at: committed_at,
        base_commit_height: base_sha && @repo.commit_height(base_sha),
        # the major the base commit itself belongs to, not the newest one that
        # could build the patch. PgMajorBackfill reads the same number back off
        # patch_ci_runs, which agrees only because CI builds the base's own era.
        pg_major: base_sha && @era.major_for(base_sha) }
    end

    # The four columns that only mean anything together: when we tried master,
    # which master, and what it said. Written on every real attempt and never on
    # an infra failure, so a set master_apply_error is always a verdict on the
    # patchset - and master_apply_sha names the commit it was reached against,
    # which is the only way to tell "conflicts with the master we have" from
    # "conflicted with some master last week". master moves several times a day.
    def touch_master_apply(attempt, now: Time.current)
      @record.assign_attributes(last_master_apply_at: now, master_apply_sha: attempt[:sha],
                                master_apply_error: attempt[:error],
                                master_conflict_files: attempt[:conflict_files] || [])
    end

    def applied_attempt(master_sha)
      { sha: master_sha, error: nil, conflict_files: [] }
    end

    def failed_attempt(master_sha, result)
      { sha: master_sha, error: clip(result.output), conflict_files: result.conflict_files }
    end

    def clip(text)
      text.to_s.scrub("?").slice(0, 20_000)
    end
  end
end
