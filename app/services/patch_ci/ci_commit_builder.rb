module PatchCi
  class CiCommitBuilder
    MissingCommittedAt = Class.new(ArgumentError)

    IDENTITY = [ "-c", "user.name=hackorum", "-c", "user.email=git@hackorum.dev",
                 "-c", "maintenance.auto=false", "-c", "gc.auto=0" ].freeze

    STUB_PATH = ".github/workflows/hackorum-ci.yml"
    UPSTREAM_PATH = ".github/workflows/pg-ci.yml"
    REUSABLE = "hackorum-dev/postgres-ci/.github/workflows/patch-ci.yml@main"

    def initialize(worktree)
      @wt = worktree
    end

    # Returns the new head sha and moves branch to it. Fixed identity plus
    # dates derived from the submission time make this deterministic: same
    # branch, same inputs, same committed_at reproduce the same sha, so a
    # re-push is a no-op.
    def build(branch:, base_sha:, on_master:, pg_major:, topic_id:, message_index:,
              committed_at:, slug: nil)
      raise MissingCommittedAt, "committed_at is required for deterministic commits" unless committed_at

      @wt.run!("checkout", "--quiet", "--force", "--detach", branch)
      @wt.run!("clean", "-fdxq")
      drop_existing_ci_commit

      write_stub(pg_major: pg_major, topic_id: topic_id, message_index: message_index,
                 base_sha: base_sha, slug: slug)
      @wt.run!("rm", "-q", "-f", "--ignore-unmatch", "--", UPSTREAM_PATH)

      @wt.run!("add", "-A", "--", ".github")
      @wt.run!(*IDENTITY, "commit", "-q", "-m", message(
        branch: branch, base_sha: base_sha, on_master: on_master, message_index: message_index
      ), env: date_env(committed_at))

      head = @wt.rev_parse("HEAD")
      @wt.run!("branch", "-f", branch, head)
      head
    end

    private

    # a refresh re-runs on a branch that may already carry our commit; drop
    # it first so we replace it instead of stacking a second one on top
    def drop_existing_ci_commit
      return unless ours?("HEAD")
      return unless @wt.rev_parse("HEAD^") # never reset past a root commit
      @wt.run!("reset", "--hard", "--quiet", "HEAD^")
    end

    # Commit-message text is not a safe signal: patch emails are untrusted and
    # can contain any line, including a forged trailer. Identify our commit by
    # the paths it touches, which we control, plus the subject we write.
    def ours?(rev)
      return false unless @wt.run("log", "-1", "--format=%s", rev).stdout.strip
                             .start_with?("hackorum CI for ")

      paths = @wt.run("show", "--name-only", "--format=", rev).stdout.split("\n").reject(&:empty?)
      paths.any? && (paths - [ STUB_PATH, UPSTREAM_PATH ]).empty?
    end

    # slug line only when set: stubs of topics without one must stay
    # byte-identical, or every deterministic sha changes. Quoted, or a slug
    # like "true" or "null" stops being a string.
    def write_stub(pg_major:, topic_id:, message_index:, base_sha:, slug:)
      path = File.join(@wt.dir, STUB_PATH)
      FileUtils.mkdir_p(File.dirname(path))
      stub = <<~YAML
        name: hackorum patch CI
        on: push
        jobs:
          ci:
            uses: #{REUSABLE}
            permissions:
              contents: write
              packages: write
            with:
              pg_major: #{pg_major}
              topic_id: #{topic_id}
              message_index: #{message_index}
              base_sha: #{base_sha}
      YAML
      stub += "      slug: \"#{slug}\"\n" if slug.present?
      File.write(path, stub)
    end

    def message(branch:, base_sha:, on_master:, message_index:)
      <<~MSG
        hackorum CI for #{branch}

        Hackorum-Base: #{base_sha}
        Hackorum-On-Master: #{on_master ? 'yes' : 'no'}
        Hackorum-Message: #{message_index}
        Hackorum-CI: full
      MSG
    end

    def date_env(committed_at)
      date = committed_at.utc.iso8601
      { "GIT_COMMITTER_DATE" => date, "GIT_AUTHOR_DATE" => date }
    end
  end
end
