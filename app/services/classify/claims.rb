require "fileutils"

module Classify
  class Claims
    Error = Class.new(StandardError)
    Conflict = Class.new(Error)
    NotReady = Class.new(Error)

    LOCK_KEY = "classify_claim"
    RESULT_FIELDS = %i[exit_code failure_kind model effort job_dir input_tokens cached_input_tokens output_tokens].freeze
    STORED_FIELDS = %i[failure_kind model effort input_tokens cached_input_tokens output_tokens].freeze

    def self.bundles_root = Pathname.new(ENV["CLASSIFY_BUNDLES_ROOT"].presence || Rails.root.join("tmp/classify_bundles"))
    def self.bundle_dir(id) = bundles_root.join(id.to_s)
    def self.tar_path(id) = bundles_root.join("#{id}.tar.gz")

    def self.claim(worker:, phases: Queue::PHASES)
      ready!
      AdvisoryLock.with_lock(LOCK_KEY, wait: true) do
        Queue.sweep!
        prune!
        topic, phase = Queue.next(phases: phases)
        topic && ClassificationRun.create!(
          topic: topic, status: "claimed", phase: phase, worker: worker,
          claimed_at: Time.current, started_at: Time.current,
          prompt_version: BundleWriter.prompt_version,
          message_count: topic.message_count, through_message_id: topic.last_message_id
        )
      end
    end

    def self.bundle_tar(run)
      ClassificationRun.transaction do
        run.lock!
        claimed!(run)
        previous = ClassificationRun.done.where(topic_id: run.topic_id).order(:created_at, :id).last&.result
        dir = bundle_dir(run.id)
        FileUtils.rm_rf(dir)
        index = BundleWriter.new(topic: run.topic, previous: previous).write(dir.to_s)
        system("tar", "-czf", tar_path(run.id).to_s, "-C", dir.to_s, ".", exception: true)
        FileUtils.rm_rf(dir)
        run.update!(message_count: index["message_count"], through_message_id: index["through_message_id"],
                    claimed_at: Time.current)
        tar_path(run.id)
      end
    rescue Conflict, ActiveRecord::RecordNotFound
      raise
    rescue => e
      # fail the run so the worker moves on instead of retrying a 500
      cleanup(run.id)
      error = "#{e.class}: #{e.message}"
      ClassificationRun.transaction do
        run.lock!
        run.finish!(status: "failed", failure_kind: "bundle", error: error) if run.status == "claimed"
      end
      raise Conflict, "run #{run.id} bundle failed: #{error}"
    end

    def self.result!(run, fields, result_path: nil)
      merged = false
      ClassificationRun.transaction do
        run.lock!
        claimed!(run)
        if run.topic.merged_into_topic_id
          run.destroy!
          merged = true
          next
        end
        fields = fields.to_h.symbolize_keys
        run.assign_attributes(fields.slice(*STORED_FIELDS))
        duration = fields[:duration_s]&.to_f
        if fields[:timed_out]
          run.finish!(status: "timeout", error: "killed after timeout", duration_s: duration)
        elsif fields[:exit_code].to_i != 0
          head = [ "codex exit #{fields[:exit_code]}", fields[:error_message].presence ].compact.join(": ")
          run.finish!(status: "failed", error: [ head, fields[:stderr_tail].presence ].compact.join("\n"), duration_s: duration)
        elsif result_path.nil? || !File.exist?(result_path)
          run.finish!(status: "failed", failure_kind: "upload", error: "result file missing", duration_s: duration)
        else
          begin
            ClassificationRun.transaction(requires_new: true) do
              Ingestor.new(run).call(result_path.to_s)
            rescue Ingestor::Error => e
              run.finish!(status: "failed", failure_kind: "schema", error: e.message)
            end
          rescue => e
            run.reload.assign_attributes(fields.slice(*STORED_FIELDS))
            run.finish!(status: "failed", failure_kind: "ingest", error: "#{e.class}: #{e.message}")
          end
          run.update!(duration_s: duration) if duration
        end
      end
      cleanup(run.id)
      raise Conflict, "run #{run.id}: topic was merged away" if merged
      run
    end

    def self.release!(run)
      ClassificationRun.transaction do
        run.lock!
        claimed!(run)
        run.destroy!
      end
      cleanup(run.id)
    end

    def self.ready!
      return if User.exists?(username: BOT_USERNAME) && GlobalTag.active.where(name: TAGS).count == TAGS.size

      raise NotReady, "classify setup has not run (bot user or tags missing): run Classify::Setup.call!"
    end

    def self.prune!
      return unless bundles_root.directory?
      live = ClassificationRun.claimed.pluck(:id).to_set
      bundles_root.each_child do |path|
        id = path.basename.to_s[/\A(\d+)(\.tar\.gz)?\z/, 1]
        FileUtils.rm_rf(path) if id && !live.include?(id.to_i)
      end
    end

    def self.cleanup(id)
      FileUtils.rm_rf(bundle_dir(id))
      FileUtils.rm_f(tar_path(id))
    end

    def self.claimed!(run)
      raise Conflict, "run #{run.id} is #{run.status}" unless run.status == "claimed"
    end
    private_class_method :ready!, :prune!, :cleanup, :claimed!
  end
end
