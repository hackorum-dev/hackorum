#!/usr/bin/env ruby
# frozen_string_literal: true

# Lineage processor: claims topics from a hackorum server, completes the bundle
# from the local postgres checkout, runs codex, uploads the result. No database.

require "optparse"
require "socket"
require "fileutils"

options = {
  server: ENV["LINEAGE_SERVER"], token: ENV["LINEAGE_API_TOKEN"], worker: Socket.gethostname,
  repo: File.expand_path("../postgres", __dir__), jobs_root: nil,
  concurrency: 2, phases: [], timeout: nil, work: "lineage"
}
LINEAGE_PHASES = %w[trailer update discussion full lineage].freeze

OptionParser.new do |o|
  o.banner = "Usage: ruby script/lineage_processor.rb [options]"
  o.on("--server URL", "hackorum base url (default $LINEAGE_SERVER)") { |v| options[:server] = v }
  o.on("--token TOKEN", "api token (default $LINEAGE_API_TOKEN)") { |v| options[:token] = v }
  o.on("--worker NAME", "worker name (default hostname)") { |v| options[:worker] = v }
  o.on("--repo PATH", "postgres checkout (default ./postgres)") { |v| options[:repo] = v }
  o.on("--work KIND", %w[lineage classify], "lineage (default) or classify") { |v| options[:work] = v }
  o.on("--jobs-root PATH", "job dirs (default tmp/lineage_jobs, tmp/classify_jobs for classify)") { |v| options[:jobs_root] = v }
  o.on("--concurrency N", Integer, "parallel codex processes (default 2)") { |v| options[:concurrency] = v }
  o.on("--phase NAME", "only claim from this phase, repeatable (lineage: #{LINEAGE_PHASES.join(' ')}; classify: new recheck backfill)") { |v| options[:phases] << v }
  o.on("--limit N", Integer, "stop after N jobs") { |v| options[:limit] = v }
  o.on("--model NAME", "codex model (classify default: Classify::MODEL)") { |v| options[:model] = v }
  o.on("--effort LEVEL", "codex reasoning effort (classify default: Classify::EFFORT)") { |v| options[:effort] = v }
  o.on("--timeout SEC", Integer, "per-topic codex timeout (default 1200, classify 600)") { |v| options[:timeout] = v }
  o.on("--clean", "delete job dirs of uploaded runs and exit") { options[:clean] = true }
  o.on("--stats", "print queue counts and exit") { options[:stats] = true }
end.parse!

classify = options[:work] == "classify"
options[:jobs_root] ||= File.expand_path("../tmp/#{options[:work]}_jobs", __dir__)
options[:timeout] ||= classify ? 600 : 1200

if options[:clean]
  Dir.glob(File.join(options[:jobs_root], "*", "*", "uploaded")).each { |marker| FileUtils.rm_rf(File.dirname(marker)) }
  puts "cleaned"
  exit 0
end

abort "server missing: --server or LINEAGE_SERVER" if options[:server].to_s.empty?
abort "token missing: --token or LINEAGE_API_TOKEN" if options[:token].to_s.empty?
abort "concurrency must be positive" if options[:concurrency] <= 0
require_relative "../config/environment"

if classify
  options[:model] ||= Classify::MODEL
  options[:effort] ||= Classify::EFFORT
end

valid_phases = classify ? Classify::Queue::PHASES : LINEAGE_PHASES
bad = options[:phases] - valid_phases
abort "invalid phase: #{bad.join(', ')} (valid: #{valid_phases.join(', ')})" if bad.any?

client = Lineage::Processor::Client.new(server: options[:server], token: options[:token],
                                        prefix: classify ? "/api/classify" : "/api/lineage")

if options[:stats]
  begin
    client.queue.each { |phase, c| puts format("%-8s remaining %6d  claimed %3d  done %6d", phase, c["remaining"], c["claimed"], c["done"]) }
  rescue Lineage::Processor::Client::Error => e
    warn "server error: #{e.message}"
    exit 1
  end
  exit 0
end

abort "postgres checkout not found at #{options[:repo]}" unless classify || File.directory?(File.join(options[:repo], ".git"))

stop = Lineage::Processor::StopFlag.new
signalled = false
runners = []
mutex = Mutex.new
done = 0
in_flight = 0
say = ->(line) { mutex.synchronize { puts line } }

%w[INT TERM].each do |sig|
  trap(sig) do
    signalled = true
    stop.set!
    runners.each(&:abort!)
  end
end

new_runner = if classify
  -> { Classify.runner(model: options[:model], effort: options[:effort], timeout: options[:timeout]) }
else
  -> { Lineage::CodexRunner.new(repo_path: options[:repo], model: options[:model], effort: options[:effort], timeout: options[:timeout]) }
end
begin
  new_runner.call.prepare_home!
rescue RuntimeError => e
  abort e.message
end

threads = options[:concurrency].times.map do |i|
  Thread.new do
    runner = new_runner.call
    mutex.synchronize { runners << runner }
    worker = Lineage::Processor::Worker.new(client: client, runner: runner, repo_path: options[:repo],
                                            jobs_root: options[:jobs_root], worker_name: "#{options[:worker]}-#{i}",
                                            phases: options[:phases].presence, stop: stop, say: say,
                                            completer: classify ? Classify::NoopCompleter : nil)
    loop do
      claimed = mutex.synchronize do
        next false if options[:limit] && done + in_flight >= options[:limit]
        in_flight += 1
        true
      end
      break unless claimed
      outcome = begin
        worker.run_one
      rescue Exception
        mutex.synchronize { in_flight -= 1 }
        raise
      end
      n = mutex.synchronize do
        in_flight -= 1
        done += 1 if outcome.kind == :done
        done
      end
      case outcome.kind
      when :done
        say.call(format("[%d] topic %d run %d: %s %s %s", n, outcome.claim.topic_id, outcome.claim.run_id, outcome.status,
                        outcome.duration_s ? "#{outcome.duration_s.round}s" : "", outcome.error.to_s.lines.first.to_s.strip))
      when :refused
        say.call(format("refused topic %d run %d: %s", outcome.claim.topic_id, outcome.claim.run_id, outcome.error.to_s.lines.first.to_s.strip))
      end
      break unless %i[done refused].include?(outcome.kind)
    end
  rescue => e
    stop.set!
    say.call("worker #{i}: #{e.class}: #{e.message}")
  end
end
threads.each(&:join)

say.call("#{done} jobs uploaded")
exit 130 if signalled
exit(stop.set? ? 2 : 0)
