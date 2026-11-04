module Topics
  class CommitSummary
    SHA_TOKEN_RE = /\b[0-9a-f]{7,40}\b/
    CLUSTER_GAP = 14.days

    attr_reader :groups

    def self.revert?(group)
      group[:subject].to_s.start_with?("Revert")
    end

    def initialize(commits, credit_sources:)
      @commits = commits
      @credit_sources = credit_sources
      @groups = Commit.group_backports(commits)
    end

    def any? = @groups.any?
    def count = @groups.size
    def latest = @groups.first
    def first = @groups.last

    def committers
      by_frequency(@groups.map { |g| g[:committer_name] })
    end

    def authors
      @authors ||= (CreditCounts.new(@groups, sources: @credit_sources).by_role["author"] || [])
                     .reject(&:llm_only?).map(&:name)
    end

    def revert_groups
      @groups.select { |g| self.class.revert?(g) }
    end

    def revert_shas
      revert_groups.flat_map { |g| member_shas(g) }.to_set
    end

    def reverted_count(group)
      tokens = commits_by_sha[group[:sha]]&.body.to_s.scan(SHA_TOKEN_RE)
      return 0 if tokens.blank?

      @groups.count do |other|
        next false if other[:sha] == group[:sha]
        member_shas(other).any? { |sha| tokens.any? { |t| sha.start_with?(t) } }
      end
    end

    def clusters
      @groups.chunk_while do |newer, older|
        newer[:committed_at] && older[:committed_at] &&
          newer[:committed_at] - older[:committed_at] <= CLUSTER_GAP
      end.to_a
    end

    def member_shas(group)
      group[:commit_ids].filter_map { |id| commits_by_id[id]&.sha }
    end

    private

    def by_frequency(names)
      names.compact_blank.tally.sort_by { |name, n| [ -n, name.downcase ] }.map(&:first)
    end

    def commits_by_sha
      @commits_by_sha ||= @commits.index_by(&:sha)
    end

    def commits_by_id
      @commits_by_id ||= @commits.index_by(&:id)
    end
  end
end
