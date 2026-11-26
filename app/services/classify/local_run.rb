require "fileutils"
require "json"

module Classify
  class LocalRun
    def self.call(topic:, model:, effort:, timeout: 600, ingest: false, jobs_root: "tmp/classify_local", **runner_opts)
      new(topic, model, effort, timeout, ingest, jobs_root, runner_opts).call
    end

    def initialize(topic, model, effort, timeout, ingest, jobs_root, runner_opts)
      @topic = topic
      @model = model
      @effort = effort
      @timeout = timeout
      @ingest = ingest
      @jobs_root = Pathname.new(jobs_root.to_s).expand_path(Rails.root)
      @runner_opts = runner_opts
    end

    def call
      dir = @jobs_root.join(@topic.id.to_s)
      FileUtils.rm_rf(dir)
      run = @ingest ? start_run : nil
      previous = ClassificationRun.done.where(topic_id: @topic.id).order(:created_at, :id).last&.result
      index = BundleWriter.new(topic: @topic, previous: previous).write(dir.to_s)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      res = Classify.runner(model: @model, effort: @effort, timeout: @timeout, **@runner_opts).call(dir.to_s)
      duration = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to_f
      path = dir.join("result.json")
      kind = failure_kind(res, path)
      finish(run, res, index, path, duration) if run
      kind = run.failure_kind if run && run.status != "done"
      { result: kind ? nil : JSON.parse(File.read(path)), usage: res.usage, duration_s: duration, failure_kind: kind }
    rescue JSON::ParserError
      { result: nil, usage: res.usage, duration_s: duration, failure_kind: "schema" }
    end

    private

    def failure_kind(res, path)
      return "timeout" if res.timed_out
      return res.failure_kind || "codex" if res.exit_code != 0
      "upload" unless File.exist?(path)
    end

    def start_run
      phase = ClassificationRun::PHASES.find { |p| Queue.phase_scope(p).exists?(id: @topic.id) } || "new"
      ClassificationRun.create!(topic: @topic, status: "claimed", phase: phase, worker: "local",
                                claimed_at: Time.current, started_at: Time.current,
                                prompt_version: BundleWriter.prompt_version)
    end

    def finish(run, res, index, path, duration)
      run.update!(message_count: index["message_count"], through_message_id: index["through_message_id"],
                  model: @model, effort: @effort, input_tokens: res.usage[:input_tokens],
                  cached_input_tokens: res.usage[:cached_input_tokens], output_tokens: res.usage[:output_tokens])
      if res.timed_out
        run.finish!(status: "timeout", error: "killed after timeout", duration_s: duration)
      elsif res.exit_code != 0
        run.finish!(status: "failed", failure_kind: res.failure_kind,
                    error: [ "codex exit #{res.exit_code}", res.error_message.presence ].compact.join(": "), duration_s: duration)
      elsif !File.exist?(path)
        run.finish!(status: "failed", failure_kind: "upload", error: "result file missing", duration_s: duration)
      else
        ingest(run, path)
        run.update!(duration_s: duration)
      end
    end

    def ingest(run, path)
      ClassificationRun.transaction(requires_new: true) do
        Ingestor.new(run).call(path.to_s)
      rescue Ingestor::Error => e
        run.finish!(status: "failed", failure_kind: "schema", error: e.message)
      end
    rescue => e
      run.reload.finish!(status: "failed", failure_kind: "ingest", error: "#{e.class}: #{e.message}")
    end
  end
end
