require "fileutils"

module Lineage
  # One topic end to end. candidates: [{ commit:, origin:, overlap: }]
  class TopicJob
    def initialize(topic:, candidates:, repo_path:, jobs_root:, worktrees_dir:, runner:,
                   apply: true, link: true, link_threshold: 0.8, dry_run: false, worktree_name: "lineage0", mode: nil)
      @topic = topic
      @candidates = candidates
      @mode = mode || (candidates.any? { |c| c[:origin] == "trailer" } ? "trailer" : "full")
      @repo_path = repo_path.to_s
      @jobs_root = jobs_root.to_s
      @worktrees_dir = worktrees_dir.to_s
      @runner = runner
      @apply = apply
      @link = link
      @link_threshold = link_threshold
      @dry_run = dry_run
      @worktree_name = worktree_name
    end

    def call
      run = PatchsetRun.create!(topic: @topic, status: "running", started_at: Time.current, mode: @mode,
                                prompt_version: JobBundle.prompt_version, model: @runner.model)
      begin
        job_dir = File.join(@jobs_root, @topic.id.to_s, run.id.to_s)
        FileUtils.mkdir_p(job_dir)
        run.update!(job_dir: job_dir)

        index = build_bundle(run, job_dir)
        if @dry_run
          run.update!(status: "queued")
          return run
        end

        result = @runner.call(job_dir)
        run.assign_attributes(exit_code: result.exit_code, failure_kind: result.failure_kind, **result.usage)
        if result.timed_out
          run.finish!(status: "timeout", error: "killed after timeout")
        elsif result.exit_code != 0
          head = [ "codex exit #{result.exit_code}", result.error_message ].compact.join(": ")
          run.finish!(status: "failed", error: "#{head}\n#{CodexRunner.stderr_tail(job_dir)}")
        else
          ResultIngestor.new(run: run, index: index, link_threshold: @link_threshold, link: @link, mode: @mode)
                        .call(File.join(job_dir, "result.json"))
        end
      rescue ResultIngestor::Error
        run.update!(failure_kind: "schema")
      rescue => e
        run.finish!(status: "failed", error: "#{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
      end
      run
    end

    private

    def build_bundle(run, job_dir)
      branches = if @apply
        ->(patchsets) { BranchApplier.new(repo_path: @repo_path, worktrees_dir: @worktrees_dir, worktree_name: @worktree_name).call(patchsets) }
      end
      index = BundleWriter.new(run: run, topic: @topic, candidates: @candidates, mode: @mode, branches: branches).call(job_dir)
      run.update!(through_message_id: index["through_message_id"])
      BundleCompleter.new(repo_path: @repo_path).call(job_dir)
      index
    end
  end
end
