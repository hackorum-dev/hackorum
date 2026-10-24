module PatchBranches
  class BaseCommitDetector
    Detection = Struct.new(:sha, :source, keyword_init: true)

    HISTORY_LIMIT = 3000
    HISTORY_DEADLINE = 30

    def initialize(repo, patch_files, submission_date: nil)
      @repo = repo
      @patch_files = patch_files
      @submission_date = submission_date
    end

    def detect
      return nil if @patch_files.empty?

      from_base_line || from_blob_hashes || from_submission_date
    end

    private

    def from_base_line
      [ @patch_files.first, @patch_files.last ].uniq.each do |file|
        content = File.read(file, encoding: "BINARY")
        next unless content =~ /^base-commit:\s*([0-9a-f]{40})\s*$/

        sha = @repo.rev_parse($1)
        return Detection.new(sha: sha, source: "base_line") if sha && @repo.upstream_commit?(sha)
      end
      nil
    end

    # path => "before" blob hash, first occurrence only: later patches in a
    # series see the result of earlier ones, not the base. A path first seen
    # with an all-zero before-hash is created by the series itself and can
    # never constrain the base, so it stays excluded for the whole series.
    def file_info
      @file_info ||= begin
        info = {}
        excluded = Set.new
        @patch_files.each do |file|
          content = File.read(file, encoding: "BINARY")
          content.scan(/^diff --git a\/(.+?) b\/\1\n(?:(?!diff --git ).*\n)*?index ([0-9a-f]+)\.\./) do |path, before|
            next if info.key?(path) || excluded.include?(path)
            if before.match?(/\A0+\z/)
              excluded << path
            else
              info[path] = before
            end
          end
        end
        info
      end
    end

    def from_blob_hashes
      return nil if file_info.empty?

      master = @repo.rev_parse("master")
      return nil unless master

      return Detection.new(sha: master, source: "master_head") if matches?(master)

      args = [ "log", "master", "--pretty=format:%H", "-n", HISTORY_LIMIT.to_s ]
      args += [ "--until", @submission_date.iso8601 ] if @submission_date
      commits = @repo.run(*args, "--", *file_info.keys).stdout.split("\n")

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + HISTORY_DEADLINE
      commits.each do |commit|
        next if commit.empty?
        return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        return Detection.new(sha: commit, source: "history") if matches?(commit)
      end

      nil
    end

    def from_submission_date
      return nil unless @submission_date

      result = @repo.run("rev-list", "-1", "--before", @submission_date.iso8601, "master")
      sha = result.stdout.strip
      return nil unless result.success? && sha.match?(/\A[0-9a-f]{40}\z/)

      Detection.new(sha: sha, source: "submission_head")
    end

    def matches?(commit)
      blobs = @repo.blob_shas(commit, file_info.keys)
      file_info.all? do |path, before|
        blob = blobs[path]
        blob && (blob == before || blob.start_with?(before) || before.start_with?(blob))
      end
    end
  end
end
