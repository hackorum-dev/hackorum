require "open3"
require "fileutils"

module PatchBranches
  class GitRepo
    Error = Class.new(StandardError)

    Result = Struct.new(:stdout, :stderr, :exitstatus) do
      def success?
        exitstatus == 0
      end

      def output
        [ stdout, stderr ].reject { |s| s.to_s.empty? }.join("\n")
      end
    end

    attr_reader :dir

    def initialize(dir)
      @dir = dir.to_s
    end

    # scrub: git output can contain invalid UTF-8 (patch content in errors),
    # callers run regexes over it. raw: skips it for callers that parse byte
    # offsets out of the output, where a scrub substitution would shift them;
    # the output is tagged binary there so the byte contract enforces itself.
    def run(*args, env: {}, stdin: nil, raw: false)
      opts = { chdir: @dir }
      opts[:stdin_data] = stdin if stdin
      stdout, stderr, status = Open3.capture3(env, "git", *args, **opts)
      if raw
        stdout.force_encoding(Encoding::BINARY)
        stderr.force_encoding(Encoding::BINARY)
      else
        stdout, stderr = stdout.scrub, stderr.scrub
      end
      Result.new(stdout, stderr, status.exitstatus)
    end

    def run!(*args, **opts)
      result = run(*args, **opts)
      raise Error, "git #{args.join(' ')} failed: #{result.output}" unless result.success?
      result
    end

    def rev_parse(ref)
      result = run("rev-parse", "--verify", "--quiet", "#{ref}^{commit}")
      result.success? ? result.stdout.strip : nil
    end

    def blob_sha(commit, path)
      result = run("rev-parse", "--verify", "--quiet", "#{commit}:#{path}")
      result.success? ? result.stdout.strip : nil
    end

    # path => blob sha for all requested paths present at commit, one git
    # spawn total; missing paths are simply absent from the hash
    def blob_shas(commit, paths)
      result = run("ls-tree", "-z", commit, "--", *paths)
      return {} unless result.success?

      result.stdout.split("\0").each_with_object({}) do |entry, blobs|
        meta, path = entry.split("\t", 2)
        next unless meta && path
        _mode, type, sha = meta.split(" ", 3)
        blobs[path] = sha if type == "blob"
      end
    end

    # reachable from master, an upstream branch or a tag; anything else
    # (rejected patch branches, fetched CI refs) is local and untrusted
    def upstream_commit?(sha, remote: "postgres")
      return false unless sha.to_s.match?(/\A[0-9a-f]{40}\z/)
      return true if run("merge-base", "--is-ancestor", sha, "refs/heads/master").success?

      result = run("for-each-ref", "--count=1", "--contains", sha, "--format=%(refname)",
                   "refs/remotes/#{remote}/", "refs/tags/")
      result.success? && result.stdout.strip.present?
    end

    # committer time of a commit, nil when the sha is unknown
    def commit_time(sha)
      result = run("show", "-s", "--format=%cI", "#{sha}^{commit}")
      return nil unless result.success?
      Time.zone.parse(result.stdout.strip)
    rescue ArgumentError
      nil
    end

    # ancestry count from root; for master ancestors (the common case, master
    # is linear) height differences are commit distances. A non-master base
    # (rare base_line rows landing on a REL_*_STABLE tag) yields an inflated
    # height that understates staleness - display-only, accepted.
    def commit_height(sha)
      result = run("rev-list", "--count", "#{sha}^{commit}")
      result.success? ? result.stdout.strip.to_i : nil
    end

    # File.exist? alone is not enough: a missing .git makes git walk up to
    # the parent repo, so rev_parse alone is not enough either (it would
    # resolve HEAD there instead of failing). Need both.
    def healthy_worktree?
      File.exist?(File.join(@dir, ".git")) && !!rev_parse("HEAD")
    end

    # (re)create the worktree at path if it is missing or broken; a
    # worktree killed mid-setup can look present but broken forever otherwise
    def ensure_worktree!(path, branch: "master")
      return if GitRepo.new(path).healthy_worktree?

      FileUtils.mkdir_p(File.dirname(path))
      run("worktree", "remove", "--force", path)
      FileUtils.rm_rf(path)
      run("worktree", "prune")
      run!("worktree", "add", "--quiet", "--detach", path, branch)
    end
  end
end
