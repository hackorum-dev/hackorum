require "fileutils"

module Lineage
  module Processor
    class Worker
      CAPACITY_RETRY_SLEEPS = [ 60, 180, 300 ].freeze
      SERVER_RETRY_SLEEPS = [ 10, 30, 60, 120, 300 ].freeze
      RELEASE_RETRY_SLEEPS = [ 5, 15, 45 ].freeze
      STOP_KINDS = %w[usage_limit capacity aborted].freeze
      MAX_CONSECUTIVE_FAILURES = 3
      COUNTED_FAILURE_KINDS = %w[processor codex].freeze
      BUNDLE_POLL_SECONDS = 5
      BUNDLE_WAIT_SECONDS = 1800
      # kind: :done (server took the result), :refused (server no longer wanted it, not a stop), :empty, :stopped
      Outcome = Struct.new(:kind, :claim, :status, :duration_s, :error, keyword_init: true)

      def initialize(client:, runner:, jobs_root:, worker_name:, stop:, phases: nil, repo_path: nil, completer: nil,
                     say: ->(_) { }, capacity_sleeps: CAPACITY_RETRY_SLEEPS, server_sleeps: SERVER_RETRY_SLEEPS,
                     release_sleeps: RELEASE_RETRY_SLEEPS, max_failures: MAX_CONSECUTIVE_FAILURES,
                     bundle_poll: BUNDLE_POLL_SECONDS, bundle_wait: BUNDLE_WAIT_SECONDS)
        @client = client
        @runner = runner
        @jobs_root = jobs_root.to_s
        @worker_name = worker_name
        @stop = stop
        @phases = phases
        @completer = completer || BundleCompleter.new(repo_path: repo_path)
        @say = say
        @capacity_sleeps = capacity_sleeps
        @server_sleeps = server_sleeps
        @release_sleeps = release_sleeps
        @max_failures = max_failures
        @bundle_poll = bundle_poll
        @bundle_wait = bundle_wait
        @failures = 0
        @bundle_failures = 0
      end

      def run_one
        return Outcome.new(kind: :stopped) if @stop.set?
        claim = with_retries("claim") { @client.claim(worker: @worker_name, phases: @phases) }
        return Outcome.new(kind: :empty) unless claim
        process(claim)
      rescue Client::Error => e
        @say.call("server error: #{e.message}")
        @stop.set!
        release(claim) if claim
        Outcome.new(kind: :stopped, claim: claim, error: e.message)
      end

      private

      def process(claim)
        job_dir = File.join(@jobs_root, claim.topic_id.to_s, claim.run_id.to_s)
        FileUtils.mkdir_p(job_dir)
        tar = begin
          fetch_bundle(claim, File.join(job_dir, "bundle.tar.gz"))
        rescue Client::Conflict => e
          return bundle_refused(claim, e)
        end
        unless tar
          release(claim)
          return Outcome.new(kind: :stopped, claim: claim, status: "aborted")
        end
        result, duration = prepare_and_run(job_dir, tar)
        @capacity_sleeps.each do |s|
          break unless result.failure_kind == "capacity" && !@stop.set?
          @say.call("capacity error on topic #{claim.topic_id}, retrying in #{s}s: #{result.error_message}")
          pause(s)
          result, duration = run_codex(job_dir)
        end
        if STOP_KINDS.include?(result.failure_kind)
          @say.call("#{result.failure_kind} on topic #{claim.topic_id}, releasing claim #{claim.run_id}: #{result.error_message}")
          @stop.set!
          release(claim)
          return Outcome.new(kind: :stopped, claim: claim, status: result.failure_kind, error: result.error_message)
        end
        finish(claim, result, duration, job_dir)
      end

      # -> tarball path, or nil when stopped while the server builds it
      def fetch_bundle(claim, to)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @bundle_wait
        loop do
          tar = with_retries("download of run #{claim.run_id}") { @client.download_bundle(claim.run_id, to: to) }
          if tar
            @bundle_failures = 0
            return tar
          end
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            raise Client::Error, "bundle of run #{claim.run_id} not ready after #{@bundle_wait}s"
          end
          pause(@bundle_poll)
          return nil if @stop.set?
        end
      end

      def bundle_refused(claim, e)
        @bundle_failures += 1
        @say.call("bundle of run #{claim.run_id} refused: #{e.message}")
        if @bundle_failures >= @max_failures
          @say.call("#{@bundle_failures} bundles refused in a row, stopping")
          @stop.set!
          return Outcome.new(kind: :stopped, claim: claim, error: e.message)
        end
        Outcome.new(kind: :refused, claim: claim, error: e.message)
      end

      def finish(claim, result, duration, job_dir)
        fields = upload_fields(result, duration, job_dir)
        reply = upload(claim, fields, File.join(job_dir, "result.json"))
        return Outcome.new(kind: :stopped, claim: claim, error: "upload failed") unless reply
        FileUtils.touch(File.join(job_dir, "uploaded"))
        count_failure(reply, fields)
        if @failures >= @max_failures
          @say.call("#{@failures} #{fields[:failure_kind]} failures in a row, stopping")
          @stop.set!
          return Outcome.new(kind: :stopped, claim: claim, status: reply["status"], duration_s: duration, error: reply["error"])
        end
        Outcome.new(kind: :done, claim: claim, status: reply["status"], duration_s: duration, error: reply["error"])
      rescue Client::Conflict => e
        @say.call("run #{claim.run_id} refused by the server: #{e.message}")
        Outcome.new(kind: :refused, claim: claim, duration_s: duration, error: e.message)
      end

      def count_failure(reply, fields)
        counted = %w[failed timeout].include?(reply["status"]) && COUNTED_FAILURE_KINDS.include?(fields[:failure_kind])
        @failures = counted ? @failures + 1 : 0
      end

      def prepare_and_run(job_dir, tar)
        system("tar", "-xzf", tar, "-C", job_dir, exception: true)
        @completer.call(job_dir)
        run_codex(job_dir)
      rescue Client::Error
        raise
      rescue => e
        [ processor_failure(e), nil ]
      end

      # the stop flag may have been set while we were downloading, completing or sleeping
      def run_codex(job_dir)
        return [ CodexRunner::Result.aborted([]), nil ] if @stop.set?
        timed { @runner.call(job_dir) }
      rescue => e
        [ processor_failure(e), nil ]
      end

      def processor_failure(e)
        CodexRunner::Result.new(exit_code: -1, timed_out: false, aborted: false, command: [], failure_kind: "processor",
                                error_message: "#{e.class}: #{e.message}", usage: {})
      end

      def timed
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = yield
        [ result, (Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0).round(1) ]
      end

      def upload_fields(result, duration, job_dir)
        { exit_code: result.exit_code, timed_out: result.timed_out, failure_kind: result.failure_kind,
          error_message: result.error_message, duration_s: duration, model: @runner.model, effort: @runner.effort,
          job_dir: job_dir, stderr_tail: CodexRunner.stderr_tail(job_dir).presence, **result.usage }
      end

      # -> reply hash, or nil after the retries ran out (claim released, stop set); Conflict passes through
      def upload(claim, fields, result_path)
        with_retries("upload of run #{claim.run_id}") do
          @client.submit_result(claim.run_id, fields, result_path: File.exist?(result_path) ? result_path : nil)
        end
      rescue Client::Conflict
        raise
      rescue Client::Error => e
        @say.call("upload of run #{claim.run_id} gave up, releasing: #{e.message}")
        @stop.set!
        release(claim)
        nil
      end

      # release runs after a stop, so it ignores the flag
      def release(claim)
        with_retries("release of run #{claim.run_id}", sleeps: @release_sleeps, stoppable: false) { @client.release(claim.run_id) }
      rescue Client::Error => e
        @say.call("release of run #{claim.run_id} failed, left for the server sweep: #{e.message}")
      end

      # Conflict and the last Error pass through
      def with_retries(what, sleeps: @server_sleeps, stoppable: true)
        attempts = 0
        begin
          yield
        rescue Client::Conflict
          raise
        rescue Client::Error => e
          raise if attempts >= sleeps.size || (stoppable && @stop.set?)
          @say.call("#{what} failed (#{e.message}), retrying in #{sleeps[attempts]}s")
          pause(sleeps[attempts], stoppable: stoppable)
          raise if stoppable && @stop.set?
          attempts += 1
          retry
        end
      end

      def pause(seconds, stoppable: true)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
        loop do
          left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break if left <= 0 || (stoppable && @stop.set?)
          sleep [ left, 1 ].min
        end
      end
    end
  end
end
