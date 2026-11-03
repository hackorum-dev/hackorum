#!/usr/bin/env ruby
# frozen_string_literal: true

# Patchset lineage prototype: metrics + codex per topic. See --help.

require "optparse"

options = {
  recent_from: "2018-01-01", concurrency: 2, timeout: 1200, link_threshold: 0.8,
  link: true, apply: true, limit: 50,
  repo: File.expand_path("../postgres", __dir__),
  jobs_root: File.expand_path("../tmp/patchset_jobs", __dir__),
  worktrees: File.expand_path("../tmp/lineage_worktrees", __dir__),
  commits: []
}

OptionParser.new do |o|
  o.banner = "Usage: ruby script/patchset_lineage.rb [options]"
  o.on("--topic ID", Integer, "one topic") { |v| options[:topic] = v }
  o.on("--commit SHA", "attach a candidate commit to --topic (repeatable)") { |v| options[:commits] << v }
  o.on("--sample KIND", %w[recent old], "recent|old trial sample") { |v| options[:sample] = v }
  o.on("--limit N", Integer, "sample size (default 50)") { |v| options[:limit] = v }
  o.on("--recent-from DATE", "recent sample floor (default 2018-01-01)") { |v| options[:recent_from] = v }
  o.on("--model NAME", "codex model (default from config/lineage/codex.config.toml)") { |v| options[:model] = v }
  o.on("--effort LEVEL", "codex reasoning effort") { |v| options[:effort] = v }
  o.on("--timeout SEC", Integer, "per-topic codex timeout (default 1200)") { |v| options[:timeout] = v }
  o.on("--concurrency N", Integer, "parallel codex processes (default 2)") { |v| options[:concurrency] = v }
  o.on("--rerun", "run topics that already have a done run") { options[:rerun] = true }
  o.on("--link-threshold F", Float, "confidence floor for commit_topics llm rows (default 0.8)") { |v| options[:link_threshold] = v }
  o.on("--no-link", "never write commit_topics rows") { options[:link] = false }
  o.on("--no-apply", "skip ApplyOne for patchsets without branches") { options[:apply] = false }
  o.on("--dry-run", "build bundles and metrics only") { options[:dry_run] = true }
  o.on("--clean", "delete job dirs of done runs and exit") { options[:clean] = true }
  o.on("--stats", "summarize runs and exit") { options[:stats] = true }
  o.on("--repo PATH", "postgres checkout (default ./postgres)") { |v| options[:repo] = v }
end.parse!

abort "concurrency must be positive" if options[:concurrency] <= 0
abort "--commit needs --topic" if options[:commits].any? && !options[:topic]
ENV["RAILS_MAX_THREADS"] = [ ENV["RAILS_MAX_THREADS"].to_i, options[:concurrency] + 3 ].max.to_s
require_relative "../config/environment"

if options[:stats]
  puts "runs: #{PatchsetRun.count}"
  PatchsetRun.group(:status).count.sort.each { |s, c| puts "  #{s}: #{c}" }
  done = PatchsetRun.done
  if done.any?
    puts format("avg duration: %.0fs, avg tokens in/cached/out: %d/%d/%d",
                done.average(:duration_s).to_f, done.average(:input_tokens).to_i,
                done.average(:cached_input_tokens).to_i, done.average(:output_tokens).to_i)
  end
  puts "step kinds:"
  PatchsetLineage.where(patchset_run_id: done.select(:id)).group(:step_kind).count
                 .sort_by { |_, c| -c }.each { |k, c| puts "  #{k}: #{c}" }
  puts "verdicts:"
  CommitVerdict.where(patchset_run_id: done.select(:id)).group(:verdict).count
               .sort_by { |_, c| -c }.each { |k, c| puts "  #{k}: #{c}" }
  puts "llm links: #{CommitTopic.llm.count}"
  puts "failure kinds:"
  PatchsetRun.where(status: %w[failed timeout]).group(:failure_kind).count
             .sort_by { |_, c| -c }.each { |k, c| puts "  #{k || 'unknown'}: #{c}" }
  puts "failures:"
  PatchsetRun.where(status: %w[failed timeout]).pluck(:error).map { |e| e.to_s.lines.first.to_s.strip[0, 100] }
             .tally.sort_by { |_, c| -c }.first(10).each { |l, c| puts "  #{c}x #{l}" }
  exit 0
end

if options[:clean]
  PatchsetRun.done.where.not(job_dir: nil).find_each do |run|
    next unless run.job_dir.start_with?(options[:jobs_root])
    FileUtils.rm_rf(run.job_dir)
    run.update_column(:job_dir, nil)
  end
  puts "cleaned"
  exit 0
end

jobs =
  if options[:topic]
    topic = Topic.find(options[:topic])
    cands = Lineage::CandidateFinder.trailer_commits(topic).map { |c| { commit: c, origin: "trailer", overlap: nil } }
    options[:commits].each do |sha|
      commit = Commit.find_by!(sha: sha)
      cands << { commit: commit, origin: "manual", overlap: nil } unless cands.any? { |c| c[:commit].id == commit.id }
    end
    [ [ topic, cands ] ]
  elsif options[:sample] == "recent"
    Lineage::Sampler.recent(limit: options[:limit], from: Time.zone.parse(options[:recent_from]))
  elsif options[:sample] == "old"
    window = Lineage::Sampler::OLD_FROM..Lineage::Sampler::OLD_UNTIL
    if PatchSubmissionFile.joins(:message).where(messages: { created_at: window }).none?
      abort "patch_submission_files is empty for the old window, run: " \
            "FROM=1998-01-01 TO=2014-02-01 mise exec -- bundle exec rake patch_submission_files:backfill"
    end
    Lineage::Sampler.old(limit: options[:limit])
  else
    abort "need --topic ID or --sample recent|old"
  end

jobs.reject! { |topic, _| PatchsetRun.current_for(topic.id) } unless options[:rerun]
puts "#{jobs.size} topics to run"

new_runner = lambda do
  Lineage::CodexRunner.new(repo_path: options[:repo], model: options[:model],
                           effort: options[:effort], timeout: options[:timeout])
end

CAPACITY_RETRY_SLEEP = 60

run_pool = lambda do
  queue = Queue.new
  jobs.each { |j| queue << j }
  mutex = Mutex.new
  done = 0
  aborted = false

  say = ->(line) { mutex.synchronize { puts line } }

  run_topic = lambda do |topic, cands, worker|
    ActiveRecord::Base.connection_pool.with_connection do
      Lineage::TopicJob.new(topic: topic, candidates: cands, repo_path: options[:repo],
                            jobs_root: options[:jobs_root], worktrees_dir: options[:worktrees],
                            runner: worker[:runner], apply: options[:apply], link: options[:link],
                            link_threshold: options[:link_threshold], dry_run: options[:dry_run],
                            worktree_name: "lineage#{worker[:index]}").call
    end
  end

  report = lambda do |topic, run|
    mutex.synchronize do
      done += 1
      puts format("[%d/%d] topic %d run %d: %s %s %s", done, jobs.size, topic.id, run.id, run.status,
                  run.duration_s ? "#{run.duration_s.round}s" : "", run.error.to_s.lines.first.to_s.strip)
    end
  end

  work = lambda do |topic, cands, worker|
    run = run_topic.call(topic, cands, worker)
    if run.failure_kind == "capacity"
      say.call("retrying topic #{topic.id} after capacity error: #{run.error.to_s.lines.first.to_s.strip}")
      sleep CAPACITY_RETRY_SLEEP
      run = run_topic.call(topic, cands, worker)
    end
    report.call(topic, run)
    return unless run.failure_kind == "usage_limit"
    say.call("usage limit hit on topic #{topic.id}, draining queue: #{run.error.to_s.lines.first.to_s.strip}")
    aborted = true
    queue.clear
  end

  threads = options[:concurrency].times.map do |i|
    Thread.new do
      worker = { index: i, runner: new_runner.call }
      loop do
        topic, cands = begin
          queue.pop(true)
        rescue ThreadError
          break
        end
        begin
          work.call(topic, cands, worker)
        rescue => e
          say.call("topic #{topic&.id}: #{e.class}: #{e.message}")
        end
      end
    end
  end
  threads.each(&:join)
  aborted ? :aborted : :ok
end

# workers must not race on git worktree add or the auth symlink
new_runner.call.prepare_home! unless options[:dry_run]
if options[:apply] && !options[:dry_run]
  repo = PatchBranches::GitRepo.new(options[:repo])
  options[:concurrency].times { |i| repo.ensure_worktree!(File.join(options[:worktrees], "lineage#{i}")) }
  # same key as the CI orchestrator: both write branch refs in the same repo
  outcome = AdvisoryLock.with_lock("patch_ci_orchestrator", &run_pool)
  abort "patch_ci_orchestrator lock held elsewhere, not running" unless outcome
else
  outcome = run_pool.call
end
exit 2 if outcome == :aborted
