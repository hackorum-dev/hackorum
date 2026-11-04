require "fileutils"

module Lineage
  module Processor
    class Worker
      CAPACITY_RETRY_SLEEP = 60
      UPLOAD_RETRY_SLEEPS = [ 5, 15, 45 ].freeze
      STOP_KINDS = %w[usage_limit capacity aborted].freeze
      MAX_CONSECUTIVE_FAILURES = 3
      COUNTED_FAILURE_KINDS = %w[processor codex].freeze
      # kind: :done (server took the result), :refused (server no longer wanted it, not a stop), :empty, :stopped
      Outcome = Struct.new(:kind, :claim, :status, :duration_s, :error, keyword_init: true)

      def initialize(client:, runner:, jobs_root:, worker_name:, stop:, phases: nil, repo_path: nil, completer: nil,
                     say: ->(_) { }, capacity_sleep: CAPACITY_RETRY_SLEEP, upload_sleeps: UPLOAD_RETRY_SLEEPS,
                     max_failures: MAX_CONSECUTIVE_FAILURES)
        @client = client
        @runner = runner
        @jobs_root = jobs_root.to_s
        @worker_name = worker_name
        @stop = stop
        @phases = phases
        @completer = completer || BundleCompleter.new(repo_path: repo_path)
        @say = say
        @capacity_sleep = capacity_sleep
        @upload_sleeps = upload_sleeps
        @max_failures = max_failures
        @failures = 0
      end

      def run_one
        return Outcome.new(kind: :stopped) if @stop.set?
        claim = @client.claim(worker: @worker_name, phases: @phases)
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
        tar = @client.download_bundle(claim.run_id, to: File.join(job_dir, "bundle.tar.gz"))
        result, duration = prepare_and_run(job_dir, tar)
        if result.failure_kind == "capacity" && !@stop.set?
          @say.call("capacity error on topic #{claim.topic_id}, retrying in #{@capacity_sleep}s: #{result.error_message}")
          sleep @capacity_sleep
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
        attempts = 0
        begin
          @client.submit_result(claim.run_id, fields, result_path: File.exist?(result_path) ? result_path : nil)
        rescue Client::Conflict
          raise
        rescue Client::Error => e
          if attempts < @upload_sleeps.size
            @say.call("upload of run #{claim.run_id} failed (#{e.message}), retrying in #{@upload_sleeps[attempts]}s")
            sleep @upload_sleeps[attempts]
            attempts += 1
            retry
          end
          @say.call("upload of run #{claim.run_id} failed #{attempts + 1} times, releasing: #{e.message}")
          @stop.set!
          release(claim)
          nil
        end
      end

      def release(claim)
        @client.release(claim.run_id)
      rescue Client::Error => e
        @say.call("release of run #{claim.run_id} failed: #{e.message}")
      end
    end
  end
end
