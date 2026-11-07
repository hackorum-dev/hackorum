#!/usr/bin/env ruby
# frozen_string_literal: true

# One-off: requeue topics judged while the processor's checkout lacked the
# commit. With no diff the model had to answer undecided, and a done run keeps
# the topic out of the queue for good. Deleting the run (lineages and verdicts
# go with it) puts the topic back; the rerun rewrites its LLM credits and links.
#
# Picks current runs with an undecided verdict whose evidence says the diff was
# missing. Prints what it would do and writes nothing unless --commit is given.
require_relative "../config/environment"

MISSING_DIFF = /bad object|diff_available(\s*=\s*|\s+is\s+)false|diff (is )?unavailable|no (supplied |commit )?diff|cannot (find|resolve) \[commit/i

commit = ARGV.include?("--commit")

current = PatchsetRun.done.select("DISTINCT ON (topic_id) id").order(:topic_id, created_at: :desc, id: :desc)
verdicts = CommitVerdict.where(patchset_run_id: current, verdict: "undecided").includes(:commit)
hits = verdicts.select { |v| v.evidence.to_s.match?(MISSING_DIFF) }
skipped = verdicts - hits
runs = PatchsetRun.where(id: hits.map(&:patchset_run_id).uniq).order(:id)

puts "undecided verdicts in current runs: #{verdicts.size}"
puts "missing diff: #{hits.size} verdicts in #{runs.size} runs"
hits.group_by(&:patchset_run_id).sort.each do |run_id, vs|
  puts "  run #{run_id} topic #{vs.first.topic_id}: #{vs.map { |v| v.commit.sha[0, 10] }.join(' ')}"
end
puts "other undecided, left alone: #{skipped.size}"
skipped.each { |v| puts "  run #{v.patchset_run_id} #{v.commit.sha[0, 10]}: #{v.evidence.to_s.squish[0, 120]}" }

unless commit
  puts "dry run, nothing written - pass --commit to apply"
  exit
end

runs.each(&:destroy!)
puts "deleted #{runs.size} runs"
puts "trailer queue now: #{Lineage::Queue.phase_scope('trailer').unscope(:order).count}"
