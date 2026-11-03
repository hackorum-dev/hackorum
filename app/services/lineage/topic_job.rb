require "fileutils"

module Lineage
  # One topic end to end. candidates: [{ commit:, origin:, overlap: }]
  class TopicJob
    STDERR_TAIL_BYTES = 4000

    def initialize(topic:, candidates:, repo_path:, jobs_root:, worktrees_dir:, runner:,
                   apply: true, link: true, link_threshold: 0.8, dry_run: false, worktree_name: "lineage0")
      @topic = topic
      @candidates = candidates
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
      run = PatchsetRun.create!(topic: @topic, status: "running", started_at: Time.current,
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
          run.finish!(status: "failed", error: "#{head}\n#{stderr_tail(job_dir)}")
        else
          ResultIngestor.new(run: run, index: index, link_threshold: @link_threshold, link: @link)
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
      patchsets = PatchsetEnumerator.new(@topic).call(File.join(job_dir, "patchsets"))
      branches = if @apply
        BranchApplier.new(repo_path: @repo_path, worktrees_dir: @worktrees_dir, worktree_name: @worktree_name).call(patchsets)
      else
        PatchBranch.where(message_id: patchsets.map { |p| p.message.id }).index_by(&:message_id)
                   .transform_values { |r| BranchApplier.summarize(r) }
      end
      triangle = TriangleBuilder.new(@topic, patchsets)
      pairs = triangle.call
      diffs = CommitDiff.new(PatchBranches::GitRepo.new(@repo_path))
      candidates = all_candidates
      mode = candidates.any? { |c| c[:origin] == "trailer" } ? "trailer" : "full"
      entries = with_reviewers(fold_backports(candidates)).map { |c| c.merge(entry: diffs.fetch(c[:commit])) }
      scores = triangle.commit_scores(entries.map { |c| c[:entry] })
      previous = PatchsetRun.current_for(@topic.id)&.raw_result

      last_id = JobBundle.new(run: run, topic: @topic, patchsets: patchsets, candidates: entries, pairs: pairs,
                              commit_scores: scores, branches: branches, previous: previous, repo_path: @repo_path,
                              mode: mode)
                         .write(job_dir)
      run.update!(through_message_id: last_id)
      { "patchsets" => patchsets.map { |p| { "message_id" => p.message.id } },
        "candidates" => entries.map { |c|
          { "sha" => c[:commit].sha, "origin" => c[:origin],
            "backports" => c[:backports].map(&:sha), "reviewers" => c[:reviewers] }
        } }
    end

    # the ingestor drops llm links for commits this run did not judge, so every
    # currently linked commit must be judged again
    def all_candidates
      known = @candidates.map { |c| c[:commit].id }.to_set
      previous = Commit.where(id: CommitTopic.llm.where(topic_id: @topic.id).select(:commit_id))
                       .reject { |c| known.include?(c.id) }
                       .map { |c| { commit: c, origin: "previous", overlap: nil } }
      @candidates + previous
    end

    # a backport folds into its canonical commit when that is a candidate too,
    # otherwise it stays a candidate of its own
    def fold_backports(candidates)
      by_sha = candidates.index_by { |c| c[:commit].sha }
      groups = candidates.group_by { |c|
        parent = c[:commit].cherry_picked_from_sha
        by_sha.key?(parent) ? parent : c[:commit].sha
      }
      groups.map do |sha, members|
        canonical = by_sha[sha]
        origin = members.any? { |m| m[:origin] == "trailer" } ? "trailer" : canonical[:origin]
        canonical.merge(origin: origin, backports: members.map { |m| m[:commit] } - [ canonical[:commit] ])
      end
    end

    def with_reviewers(candidates)
      ids = candidates.flat_map { |c| [ c[:commit], *c[:backports] ].map(&:id) }
      names = CommitPerson.parsed.where(commit_id: ids, role: "reviewer").includes(person: :default_alias)
                          .group_by(&:commit_id)
                          .transform_values { |rows| rows.map { |r| r.raw_name.presence || r.person&.default_alias&.name } }
      candidates.map do |c|
        reviewers = [ c[:commit], *c[:backports] ].flat_map { |commit| names[commit.id] || [] }.compact.uniq
        c.merge(reviewers: reviewers)
      end
    end

    def stderr_tail(job_dir)
      path = File.join(job_dir, "stderr.txt")
      return "" unless File.exist?(path)
      text = File.read(path)
      text.byteslice([ text.bytesize - STDERR_TAIL_BYTES, 0 ].max..).scrub.lines.last(20).join
    end
  end
end
