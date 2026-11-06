require "open3"

module CommitImport
  # All git access lives here: clone/fetch, branch/tag discovery, batched
  # commit metadata. Handles two repo layouts: a bare --mirror clone (prod,
  # branches under refs/heads) and an ordinary checkout (dev, branches only
  # reachable under refs/remotes/origin).
  class Repository
    REMOTE_URL = "https://git.postgresql.org/git/postgresql.git".freeze
    RECORD_SEP = "\x1e".freeze
    FIELD_SEP = "\x1f".freeze
    # Leading record separator plus a trailing field separator after the body:
    # everything after that last separator is the --numstat file list, one
    # "added<TAB>removed<TAB>path" line per file ("-" for binary files,
    # renamed paths as "a => b" or "dir/{a => b}/f").
    LOG_FORMAT = RECORD_SEP + %w[%H %an %ae %cn %ce %aI %cI %s %b].join(FIELD_SEP) + FIELD_SEP
    # 9 %-placeholders joined by 8 separators, plus the trailing one: 9 total
    # in a clean chunk. More than 9 means a field's own text contained a
    # literal FIELD_SEP byte (git does not sanitize this, confirmed by hand).
    EXPECTED_FIELD_SEPS = 9
    SHA_FORMAT = /\A[0-9a-f]{40}\z/.freeze
    BATCH = 1000
    CLONE_TIMEOUT = 3600
    GIT_TIMEOUT = 600
    # Bounds the drain of stdout/stderr after the process itself has already
    # exited - only fires if a pipe fd somehow stays open past exit. The two
    # reader joins are bounded independently, so a call's true worst case is
    # its own timeout plus 2x this.
    READ_DRAIN_TIMEOUT = 30
    # Circuit breaker for the per-sha retry: a handful of bad shas get
    # skipped, but a systemic failure (dead volume, corrupt mirror) must not
    # grind through up to 1000 individual git calls before giving up quietly.
    MAX_CONSECUTIVE_SHA_FAILURES = 10

    Record = Struct.new(:sha, :author_name, :author_email, :committer_name, :committer_email,
                        :authored_at, :committed_at, :subject, :body, :files,
                        :lines_added, :lines_removed, keyword_init: true)

    # upstream_remote: which remote carries the postgres history. "origin" is
    # the mirror layout (/pgrepo, and an ordinary clone); the repo the
    # orchestrator owns keeps origin for the fork and calls this "postgres".
    def initialize(path: CommitImport.repo_path, upstream_remote: "origin",
                   clone_timeout: CLONE_TIMEOUT, git_timeout: GIT_TIMEOUT)
      @path = path.to_s
      @upstream_remote = upstream_remote
      @clone_timeout = clone_timeout
      @git_timeout = git_timeout
    end

    attr_reader :path

    def sync!(fetch: true)
      if repo?
        git("fetch", "--prune", "--tags", @upstream_remote, log_output: true) if fetch
      else
        raise Error, "#{@path} is not empty and not a git repository" unless empty_dir?

        clone!
      end
    end

    # [[logical_name, ref]] - logical_name is what gets stored on the commit row.
    # Memoized: callers are expected to do one sync! then one branches read,
    # not interleave a fetch mid-way and expect this to pick it up.
    def branches
      @branches ||= begin
        remote = filtered_branches(
          ref_names("refs/remotes/#{@upstream_remote}/")
            .map { |name| name.delete_prefix("#{@upstream_remote}/") }
        )
        if remote.any?
          remote.map { |name| [ name, "#{@upstream_remote}/#{name}" ] }
        else
          filtered_branches(ref_names("refs/heads/")).map { |name| [ name, name ] }
        end
      end
    end

    def rev_list(ref)
      git("rev-list", ref).lines.map(&:strip).reject(&:empty?)
    end

    def rev_list_excluding(ref, exclude)
      args = [ "rev-list", ref ] + Array(exclude).map { |e| "^#{e}" }
      git(*args).lines.map(&:strip).reject(&:empty?)
    end

    def tags
      format = [ "%(refname:short)", "%(creatordate:iso8601)", "%(objectname)", "%(*objectname)" ]
      out = git("for-each-ref", "--format=#{format.join(FIELD_SEP)}", "refs/tags/REL*")
      out.lines.filter_map do |line|
        name, date, object, peeled = line.rstrip.split(FIELD_SEP, 4)
        next if name.to_s.empty?

        { name: name, released_at: parse_time!(date, "tag #{name}"), commit_sha: peeled.presence || object }
      end
    end

    # Yields Record in batches of BATCH. A batch whose git invocation fails
    # outright is retried one sha at a time so a single poison sha can't
    # wedge every future incremental run on the same commits forever; each
    # bad sha is logged and skipped. A structurally corrupt chunk (a
    # successful call that parses wrong - unexpected separators) is likewise
    # logged and skipped rather than yielded: it never persists wrong data,
    # but it also never aborts the batch or the rest of the run.
    def commits(shas)
      return enum_for(:commits, shas) unless block_given?

      shas.each_slice(BATCH) do |slice|
        output = begin
          log_for(slice)
        rescue Error => e
          Rails.logger.warn("commit_import: batch of #{slice.size} shas failed (#{e.message}), retrying one at a time")
          nil
        end

        if output
          parse_log(output).each { |record| yield record }
        else
          retry_per_sha(slice) { |record| yield record }
        end
      end
    end

    private

    def retry_per_sha(shas)
      consecutive_failures = 0

      shas.each do |sha|
        output = log_for([ sha ])
        consecutive_failures = 0
        parse_log(output).each { |record| yield record }
      rescue Error => e
        consecutive_failures += 1
        Rails.logger.error("commit_import: skipping poison sha #{sha}: #{e.message}")

        if consecutive_failures >= MAX_CONSECUTIVE_SHA_FAILURES
          raise Error, "commit_import: #{consecutive_failures} consecutive per-sha failures, " \
                        "aborting retry (last error: #{e.message})"
        end
      end
    end

    def filtered_branches(names)
      names.select { |name| branch?(name) }
    end

    def branch?(name)
      name == "master" || name.start_with?("REL")
    end

    def repo?
      _out, _err, status = run([ "git", "-C", @path, "rev-parse", "--git-dir" ], timeout: @git_timeout)
      status.success?
    end

    def empty_dir?
      !File.exist?(@path) || (File.directory?(@path) && Dir.children(@path).empty?)
    end

    # Always clones as origin/mirror layout - upstream_remote only matters once
    # the repo already exists, provisioning a consolidated repo is ci-repo-setup's job.
    def clone!
      FileUtils.mkdir_p(File.dirname(@path))
      out, err, status = run([ "git", "clone", "--mirror", REMOTE_URL, @path ], timeout: @clone_timeout)
      raise Error, "git clone failed: #{scrub(err)}#{scrub(out)}" unless status.success?

      log_git_output("clone", err)
    end

    def ref_names(pattern)
      git("for-each-ref", "--format=%(refname:short)", pattern)
        .lines.map(&:strip).reject { |n| n.empty? || n == "HEAD" }
    end

    def log_for(shas)
      out, err, status = run(
        [ "git", "-C", @path, "-c", "core.quotepath=false",
          "log", "--no-walk", "--stdin", "--format=#{LOG_FORMAT}", "--numstat" ],
        timeout: @git_timeout, stdin_data: shas.join("\n")
      )
      raise Error, "git log failed: #{scrub(err)}" unless status.success?

      scrub(out)
    end

    def parse_log(output)
      output.split(RECORD_SEP).filter_map do |chunk|
        next if chunk.strip.empty?

        if chunk.count(FIELD_SEP) != EXPECTED_FIELD_SEPS
          log_corrupt_chunk(chunk, "unexpected separator count")
          next
        end

        f = chunk.split(FIELD_SEP, 10)
        unless f[0].to_s.match?(SHA_FORMAT)
          log_corrupt_chunk(chunk, "expected sha, got #{f[0].to_s[0, 40].inspect}")
          next
        end

        files, added, removed = parse_numstat(f[9])
        Record.new(
          sha: f[0], author_name: f[1], author_email: f[2],
          committer_name: f[3], committer_email: f[4],
          authored_at: parse_time!(f[5], "commit #{f[0]}"), committed_at: parse_time!(f[6], "commit #{f[0]}"),
          subject: f[7], body: f[8].to_s.strip,
          files: files, lines_added: added, lines_removed: removed
        )
      end
    end

    # "-" marks a binary file: listed, not counted
    def parse_numstat(text)
      files = []
      added = 0
      removed = 0
      text.to_s.each_line do |line|
        a, r, path = line.strip.split("\t", 3)
        next if path.to_s.empty?

        files << rename_target(path)
        added += a.to_i if a != "-"
        removed += r.to_i if r != "-"
      end
      [ files.uniq, added, removed ]
    end

    # git prints a rename as "a => b" or "dir/{a => b}/f"; the old path is gone
    def rename_target(path)
      return path unless path.include?(" => ")

      if path.include?("{")
        path.gsub(/\{([^{}]*) => ([^{}]*)\}/) { Regexp.last_match(2) }.squeeze("/").delete_prefix("/")
      else
        path.split(" => ", 2).last
      end
    end

    def log_corrupt_chunk(chunk, reason)
      Rails.logger.error("commit_import: corrupt git log chunk (#{reason}): #{scrub(chunk)[0, 120].inspect}")
    end

    def git(*args, log_output: false)
      out, err, status = run([ "git", "-C", @path, *args ], timeout: @git_timeout)
      raise Error, "git #{args.first} failed: #{scrub(err)}" unless status.success?

      log_git_output(args.first, err) if log_output
      scrub(out)
    end

    def log_git_output(label, err)
      text = scrub(err).to_s.strip
      Rails.logger.info("commit_import: git #{label}: #{text}") if text.present?
    end

    def parse_time!(value, context)
      parsed = Time.zone.parse(value.to_s)
      raise Error, "#{context}: invalid timestamp #{value.inspect}" if parsed.nil?

      parsed
    end

    # Commit messages and author names in the PostgreSQL history are not all
    # valid UTF-8; Postgres would reject the raw bytes.
    def scrub(text)
      text.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?")
    end

    # Open3.capture3 with no way to time out. A hung git process (network
    # stall, wedged pack negotiation) would otherwise block forever and, since
    # this runs inside an hourly AdvisoryLock job, wedge every future import.
    # Writes stdin and drains both stdout and stderr on their own threads -
    # reading them serially reintroduces the classic pipe-buffer deadlock.
    #
    # pgroup: true puts the child in its own process group. git fetch/clone
    # execve a separate git-remote-https helper for the network transport;
    # killing only the immediate pid leaves that helper running, still
    # holding the connection (and potentially still writing into the mirror
    # directory) after we've already raised and the caller thinks it's dead.
    # Killing the group takes the helper down with it.
    #
    # Known residual gap, not chased here: a D-state (uninterruptible I/O
    # wait) process cannot be killed by any signal until the underlying I/O
    # completes. Out of scope for this class.
    def run(cmd, timeout:, stdin_data: nil)
      Open3.popen3(*cmd, pgroup: true) do |stdin, stdout, stderr, wait_thread|
        writer = Thread.new do
          stdin.write(stdin_data) if stdin_data
        rescue Errno::EPIPE, IOError
        ensure
          stdin.close
        end
        out_reader = Thread.new { stdout.read }
        err_reader = Thread.new { stderr.read }

        unless wait_thread.join(timeout)
          abort_run(wait_thread, writer, out_reader, err_reader)
          raise Error, "command timed out after #{timeout}s: #{cmd.join(' ')}"
        end

        unless out_reader.join(READ_DRAIN_TIMEOUT) && err_reader.join(READ_DRAIN_TIMEOUT)
          abort_run(wait_thread, writer, out_reader, err_reader)
          raise Error, "command output drain timed out after #{READ_DRAIN_TIMEOUT}s: #{cmd.join(' ')}"
        end

        writer.join
        [ out_reader.value, err_reader.value, wait_thread.value ]
      end
    end

    def abort_run(wait_thread, writer, out_reader, err_reader)
      kill_group(wait_thread.pid)
      wait_thread.join
      writer.kill
      out_reader.kill
      err_reader.kill
    end

    def kill_group(pid)
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH
      nil
    end
  end
end
