require "fileutils"
require "json"

module Lineage
  # git half of a bundle: candidate diffs, commit-vs-patchset metrics, repo path
  class BundleCompleter
    def initialize(repo_path:)
      @repo_path = repo_path.to_s
    end

    def call(dir)
      index = JSON.parse(File.read(File.join(dir, "index.json")))
      diffs = CommitDiff.new(PatchBranches::GitRepo.new(@repo_path))
      parsed = index["patchsets"].to_h { |p| [ p["message_id"], parse(dir, p) ] }
      scores = []
      index["candidates"].each do |c|
        entry = diffs.fetch(c["sha"])
        c["diff_available"] = entry.available
        write_commit(dir, entry) if entry.available
        index["patchsets"].each do |p|
          ps = parsed[p["message_id"]]
          scores << { "sha" => c["sha"], "message_id" => p["message_id"], "ordinal" => p["ordinal"],
                      "metrics" => entry.available && ps ? DiffMetrics.compare(ps, entry.parsed) : TriangleBuilder::UNPARSED }
        end
      end
      index["repo_path"] = @repo_path
      File.write(File.join(dir, "index.json"), JSON.pretty_generate(index))
      File.write(File.join(dir, "commit_scores.json"), JSON.generate(scores))
      readme = File.join(dir, "README.md")
      File.write(readme, File.read(readme).gsub("{{repo_path}}") { @repo_path })
      index
    end

    private

    def parse(dir, p)
      return nil if p["parse_error"] || p["files"].empty?
      DiffParser.parse_files(p["files"].map { |f| File.join(dir, p["dir"], f) })
    end

    def write_commit(dir, entry)
      cdir = File.join(dir, "commits", entry.sha)
      FileUtils.mkdir_p(cdir)
      File.write(File.join(cdir, "message.txt"), entry.message_text)
      File.binwrite(File.join(cdir, "diff.patch"), entry.diff_text)
    end
  end
end
