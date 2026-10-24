module PatchCi
  # The last line of defense before a push. Refuses when it cannot verify.
  class PushGuard
    # EraSkipReset matches stored skip reasons against this, so the wording
    # lives in one place - two copies of the string would silently stop
    # matching the moment either side was reworded
    def self.no_era_image_reason(major) = "no era image for pg#{major}"

    def initialize(repo, upstream_remote: "postgres")
      @repo = repo
      @upstream_remote = upstream_remote
      @detector = EraDetector.new(repo)
    end

    # nil = safe to push; otherwise the human-readable refusal
    def check(row)
      # free row-state checks first: the planner should never emit these, but
      # this is the last line of defense and must not trust the planner
      return "row not applied" unless row.status == "applied"
      return "row superseded" if row.superseded_by_id.present?

      # the DB row is not evidence the branch exists
      head = @repo.rev_parse(row.branch_name)
      return "branch missing from repo" unless head
      return "base sha missing" if row.base_sha.blank?
      return "branch has no commits beyond base" if head == @repo.rev_parse(row.base_sha)

      changed = changed_paths(row.base_sha, head)
      return "cannot inspect changed paths" if changed.nil?
      return "patchset touches .github/" if changed.any? { |p| p.start_with?(".github/") }
      # the diff only covers base..head, a base outside upstream could carry
      # anything
      return "base not on upstream history" unless @repo.upstream_commit?(row.base_sha, remote: @upstream_remote)

      major = @detector.major_for(row.base_sha)
      return "cannot determine pg major of base" unless major
      return self.class.no_era_image_reason(major) unless @detector.supported?(major)

      nil
    end

    private

    def changed_paths(base, head)
      # -z and quotePath off: quoted names would dodge the prefix check.
      # no renames: a rename out of .github must show the old path too
      result = @repo.run("-c", "core.quotePath=false", "diff", "--name-only", "--no-renames", "-z",
                         "#{base}..#{head}")
      return nil unless result.success?
      result.stdout.split("\0")
    end
  end
end
