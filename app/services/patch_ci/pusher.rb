module PatchCi
  class Pusher
    def initialize(repo:, worktree:, remote: "origin")
      @repo = repo
      @worktree = worktree
      @remote = remote
      @detector = EraDetector.new(repo)
      @builder = CiCommitBuilder.new(worktree)
    end

    def push(record)
      major = @detector.major_for(record.base_sha)
      head = @builder.build(
        branch: record.branch_name,
        base_sha: record.base_sha,
        on_master: record.on_master,
        pg_major: major,
        topic_id: record.topic_id,
        slug: record.topic.slug,
        message_index: message_index(record),
        committed_at: record.message.created_at
      )

      # refresh is always a force-push to the same name
      result = @repo.run("push", "--force", @remote,
                         "#{record.branch_name}:refs/heads/#{record.branch_name}")
      unless result.success?
        record.update!(ci_status: "push_failed",
                       ci_skip_reason: "push failed: #{clip(result.output)}")
        return false
      end

      record.update!(pushed_head_sha: head, pushed_at: Time.current,
                     ci_status: "pushed_awaiting_ci", ci_skip_reason: nil)
      true
    rescue PatchBranches::GitRepo::Error, CiCommitBuilder::MissingCommittedAt => e
      record.update!(ci_status: "push_failed",
                     ci_skip_reason: "push failed: #{clip(e.message)}")
      false
    end

    def skip(record, reason)
      record.update!(ci_status: "ci_none", ci_skip_reason: reason)
    end

    private

    # branch names are t<topic>_<index>; the index is the same number the site
    # already shows, so read it back rather than recomputing it. Safe only
    # because PatchBranches::Runner is the sole writer of branch_name; the
    # column itself has no format constraint.
    def message_index(record)
      record.branch_name.split("_").last.to_i
    end

    def clip(text)
      text.to_s.scrub("?").slice(0, 2_000)
    end
  end
end
