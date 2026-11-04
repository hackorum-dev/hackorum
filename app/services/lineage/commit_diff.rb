module Lineage
  class CommitDiff
    Entry = Struct.new(:commit, :sha, :available, :message_text, :diff_text, :parsed, keyword_init: true)

    def initialize(repo)
      @repo = repo
    end

    def fetch(commit_or_sha)
      commit = commit_or_sha if commit_or_sha.is_a?(Commit)
      sha = commit ? commit.sha : commit_or_sha
      return Entry.new(commit: commit, sha: sha, available: false) unless @repo.rev_parse(sha)

      message = @repo.run!("show", "-s", "--format=%B", sha).stdout
      diff = @repo.run!("show", "--format=", "--no-color", "--no-ext-diff", "-M", "--first-parent", sha, raw: true).stdout
      Entry.new(commit: commit, sha: sha, available: true, message_text: message, diff_text: diff,
                parsed: DiffParser.parse(diff))
    end
  end
end
