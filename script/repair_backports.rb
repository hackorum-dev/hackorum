#!/usr/bin/env ruby
# frozen_string_literal: true

# Rebuilds commits.cherry_picked_from_sha. The pre-41b5a31 grouping marked
# master commits as backports of a same-second stable twin; the new rule only
# fills NULLs, so those stale links became master <-> stable cycles that drop
# commits from canonical counts and double them in period stats.
#
# Resets every link to the explicit cherry-pick trailer (or NULL), reruns
# assign_backports, then clears Rails.cache - closed stats periods never expire.
#
# Dry run by default: does the work in a transaction and rolls it back.
# Pass --commit to apply.
require_relative "../config/environment"

commit = ARGV.include?("--commit")

def report(label)
  conn = ActiveRecord::Base.connection
  master = Commit.on_master.where.not(cherry_picked_from_sha: nil).count
  cycles = conn.select_value(<<~SQL.squish)
    SELECT count(*) FROM commits a JOIN commits b
    ON a.cherry_picked_from_sha = b.sha AND b.cherry_picked_from_sha = a.sha AND a.id < b.id
  SQL
  puts "#{label}: master commits marked as backports #{master}, 2-cycles #{cycles}"
end

ran = false
AdvisoryLock.with_lock(CommitImportJob::LOCK_KEY) do
  ran = true
  Commit.transaction do
    report("before")

    reset = 0
    Commit.where.not(cherry_picked_from_sha: nil).select(:id, :subject, :body, :cherry_picked_from_sha).find_each do |c|
      explicit = CommitImport::TrailerParser.new(subject: c.subject, body: c.body).parse.cherry_picked_from
      next if explicit == c.cherry_picked_from_sha

      Commit.where(id: c.id).update_all(cherry_picked_from_sha: explicit)
      reset += 1
    end
    puts "reset to trailer value: #{reset}"

    CommitImport::Importer.new(repository: Object.new, fetch: false).send(:assign_backports)
    report("after")

    raise ActiveRecord::Rollback unless commit
  end
end

abort "commit import lock held, try again later" unless ran

if commit
  Rails.cache.clear
  puts "cache cleared; run script/warm_stats.rb to rewarm"
else
  puts "dry run, nothing written - pass --commit to apply"
end
