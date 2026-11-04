require "fileutils"
require "json"

module Lineage
  class CodexRunner
    ZERO_USAGE = { input_tokens: 0, cached_input_tokens: 0, output_tokens: 0 }.freeze
    Result = Struct.new(:exit_code, :timed_out, :aborted, :usage, :command, :failure_kind, :error_message, keyword_init: true) do
      def self.aborted(command)
        new(exit_code: nil, timed_out: false, aborted: true, usage: ZERO_USAGE.dup, command: command,
            failure_kind: "aborted", error_message: nil)
      end
    end
    STDERR_TAIL_BYTES = 4000

    FAILURE_PATTERNS = {
      "capacity" => /capacity|rate limit|overloaded/i,
      "usage_limit" => /usage limit|quota|insufficient|billing/i
    }.freeze

    CONFIG_SOURCE = Rails.root.join("config/lineage/codex.config.toml")
    SCHEMA_PATH = Rails.root.join("config/lineage/result.schema.json")
    PROMPT = "Read README.md in the working directory and do what it says. " \
             "Your final message must be only the JSON object the output schema describes."
    KILL_GRACE = 10

    attr_reader :model, :effort

    def initialize(repo_path:, model: nil, effort: nil, timeout: 1200,
                   codex_bin: ENV.fetch("CODEX_BIN", "codex"),
                   codex_home: Rails.root.join("tmp/codex_home").to_s,
                   auth_path: File.expand_path("~/.codex/auth.json"))
      @repo_path = repo_path.to_s
      @model = model
      @effort = effort
      @timeout = timeout
      @codex_bin = codex_bin
      @codex_home = codex_home.to_s
      @auth_path = auth_path
      @aborted = false
    end

    def call(job_dir)
      cmd = command(job_dir)
      return Result.aborted(cmd) if @aborted
      prepare_home!
      pid = Process.spawn({ "CODEX_HOME" => @codex_home }, *cmd,
                          pgroup: true,
                          in: File::NULL,
                          out: File.join(job_dir, "events.jsonl"),
                          err: File.join(job_dir, "stderr.txt"))
      status, timed_out = wait(pid)
      exit_code = status&.exitstatus || (status&.termsig && 128 + status.termsig)
      events = File.join(job_dir, "events.jsonl")
      message = error_message(events)
      Result.new(exit_code: exit_code, timed_out: timed_out, aborted: @aborted, usage: usage(events), command: cmd,
                 failure_kind: failure_kind(exit_code, timed_out, message), error_message: message)
    end

    # safe from a trap handler: just a flag, wait sends the signals; sticky, later calls do not spawn
    def abort!
      @aborted = true
    end

    def self.stderr_tail(job_dir)
      path = File.join(job_dir, "stderr.txt")
      return "" unless File.exist?(path)
      text = File.read(path)
      text.byteslice([ text.bytesize - STDERR_TAIL_BYTES, 0 ].max..).scrub.lines.last(20).join
    end

    def self.classify(message)
      return nil if message.blank?
      FAILURE_PATTERNS.each { |kind, re| return kind if message.match?(re) }
      nil
    end

    def command(job_dir)
      cmd = [ @codex_bin, "exec", "--skip-git-repo-check", "-C", job_dir,
              "-s", "workspace-write", "--output-schema", SCHEMA_PATH.to_s,
              "--json", "-o", File.join(job_dir, "result.json") ]
      cmd += [ "-m", @model ] if @model
      cmd += [ "-c", "model_reasoning_effort=\"#{@effort}\"" ] if @effort
      cmd << PROMPT
    end

    def prepare_home!
      FileUtils.mkdir_p(@codex_home)
      config = File.join(@codex_home, "config.toml")
      FileUtils.cp(CONFIG_SOURCE, config) unless File.exist?(config) && File.read(config) == File.read(CONFIG_SOURCE)
      auth = File.join(@codex_home, "auth.json")
      return if File.exist?(auth)
      File.delete(auth) if File.symlink?(auth)
      raise "codex auth file missing: #{@auth_path}" unless File.exist?(@auth_path)
      File.symlink(File.expand_path(@auth_path), auth)
    end

    private

    def wait(pid)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
      term_at = nil
      timed_out = false
      killed = false
      loop do
        _, status = Process.wait2(pid, Process::WNOHANG)
        return [ status, timed_out ] if status
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if term_at.nil? && (@aborted || now > deadline)
          timed_out = true unless @aborted
          term_at = now
          kill_group("TERM", pid)
        elsif term_at && !killed && now > term_at + KILL_GRACE
          kill_group("KILL", pid)
          killed = true
        end
        sleep 1
      end
    end

    def kill_group(sig, pid)
      Process.kill(sig, -pid)
    rescue Errno::ESRCH
      nil
    end

    def failure_kind(exit_code, timed_out, message)
      return "aborted" if @aborted
      return "timeout" if timed_out
      return nil if exit_code == 0
      self.class.classify(message) || "codex"
    end

    def events(path)
      return unless File.exist?(path)
      File.foreach(path) do |line|
        event = JSON.parse(line) rescue next
        yield event if event.is_a?(Hash)
      end
    end

    def usage(events_path)
      totals = ZERO_USAGE.dup
      events(events_path) do |event|
        next unless event["type"] == "turn.completed" && event["usage"].is_a?(Hash)
        totals.each_key { |k| totals[k] += event["usage"][k.to_s].to_i }
      end
      totals
    end

    def error_message(events_path)
      message = nil
      events(events_path) do |event|
        text = case event["type"]
        when "error" then event["message"]
        when "turn.failed" then event.dig("error", "message")
        end
        message = text if text.present?
      end
      message
    end
  end
end
