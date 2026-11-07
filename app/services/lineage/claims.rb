require "fileutils"

module Lineage
  class Claims
    Error = Class.new(StandardError)
    Conflict = Class.new(Error)

    LOCK_KEY = "lineage_claim"
    RESULT_FIELDS = %i[exit_code failure_kind model effort job_dir input_tokens cached_input_tokens output_tokens].freeze

    def self.bundles_root = Pathname.new(ENV["LINEAGE_BUNDLES_ROOT"].presence || Rails.root.join("tmp/lineage_bundles"))
    def self.bundle_dir(id) = bundles_root.join(id.to_s)
    def self.tar_path(id) = bundles_root.join("#{id}.tar.gz")
    def self.part_path(id) = bundles_root.join("#{id}.tar.gz.part")

    def self.claim(worker:, phases: Queue::PHASES)
      run = AdvisoryLock.with_lock(LOCK_KEY, wait: true) do
        Queue.sweep!
        prune!
        topic, phase = Queue.next(phases: phases)
        topic && PatchsetRun.create!(topic: topic, status: "claimed", mode: phase, worker: worker,
                                     claimed_at: Time.current, started_at: Time.current,
                                     prompt_version: JobBundle.prompt_version)
      end
      LineageBundleJob.perform_later(run.id) if run
      run
    end

    # -> tarball path, or nil while the build job runs
    def self.bundle_tar(run)
      PatchsetRun.transaction do
        run.lock!
        raise Conflict, "run #{run.id} bundle failed: #{run.error}" if run.failure_kind == "bundle"
        claimed!(run)
        if File.exist?(tar_path(run.id))
          run.update!(claimed_at: Time.current)
          tar_path(run.id)
        elsif run.bundle_index
          run.update!(bundle_index: nil)
          LineageBundleJob.perform_later(run.id)
          nil
        end
      end
    end

    def self.result!(run, fields, result_path: nil)
      PatchsetRun.transaction do
        run.lock!
        claimed!(run)
        fields = fields.to_h.symbolize_keys
        run.assign_attributes(fields.slice(*RESULT_FIELDS))
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
            ResultIngestor.new(run: run, index: run.bundle_index, mode: run.mode).call(result_path.to_s)
          rescue ResultIngestor::Error
            run.update!(failure_kind: "schema")
          end
          run.update!(duration_s: duration) if duration
        end
        cleanup(run.id)
      end
      run
    end

    def self.release!(run)
      PatchsetRun.transaction do
        run.lock!
        claimed!(run)
        run.destroy!
        cleanup(run.id)
      end
    end

    def self.build!(run)
      dir = bundle_dir(run.id)
      part = part_path(run.id)
      FileUtils.rm_rf(dir)
      FileUtils.mkdir_p(dir)
      candidates = if run.mode == "trailer"
        CandidateFinder.trailer_commits(run.topic).map { |c| { commit: c, origin: "trailer", overlap: nil } }
      else
        []
      end
      index = BundleWriter.new(run: run, topic: run.topic, candidates: candidates, mode: run.mode).call(dir.to_s)
      system("tar", "-czf", part.to_s, "-C", dir.to_s, ".", exception: true)
      PatchsetRun.transaction do
        run.lock!
        claimed!(run)
        run.update!(bundle_index: index, through_message_id: index["through_message_id"])
        File.rename(part, tar_path(run.id))
      end
    rescue Conflict, ActiveRecord::RecordNotFound
      cleanup(run.id)
    rescue => e
      cleanup(run.id)
      PatchsetRun.transaction do
        run.lock!
        run.finish!(status: "failed", failure_kind: "bundle", error: "#{e.class}: #{e.message}") if run.status == "claimed"
      end
    end

    def self.prune!
      return unless bundles_root.directory?
      live = PatchsetRun.claimed.pluck(:id).to_set
      bundles_root.each_child do |path|
        id = path.basename.to_s[/\A(\d+)(\.tar\.gz(\.part)?)?\z/, 1]
        next unless id && !live.include?(id.to_i)
        FileUtils.rm_rf(path)
      end
    end

    def self.cleanup(id)
      FileUtils.rm_rf(bundle_dir(id))
      FileUtils.rm_f(tar_path(id))
      FileUtils.rm_f(part_path(id))
    end

    def self.claimed!(run)
      raise Conflict, "run #{run.id} is #{run.status}" unless run.status == "claimed"
    end
    private_class_method :bundle_dir, :tar_path, :part_path, :prune!, :cleanup, :claimed!
  end
end
