#!/usr/bin/env ruby
# frozen_string_literal: true

# Applies CommitterReviewer to every commit: the committer of someone else's
# patch is credited as its reviewer. New imports and reparses do this on the
# way in; this fills rows for commits stored before that existed. A second
# pass mirrors those rows into committed lineage verdicts ingested before.
#
# Prints the count and writes nothing unless --commit is given.
require_relative "../config/environment"

commit = ARGV.include?("--commit")

scanned = 0
rows = 0
Commit.in_batches(of: 1000) do |batch|
  ids = batch.pluck(:id)
  scanned += ids.size
  rows += commit ? CommitterReviewer.sync!(ids) : CommitterReviewer.new(ids).entries.size
end

puts "#{scanned} commits scanned, #{rows} committer reviewer rows #{commit ? 'written' : 'to write'}"
mirrored = 0
CommitVerdict.where(verdict: CommitVerdict::COMMITTED).in_batches(of: 500) do |batch|
  mirrored += Lineage::CommitterReviews.mirror(batch, write: commit).size
end
puts "#{mirrored} verdicts #{commit ? 'mirrored' : 'to mirror'}"
puts "dry run, nothing written - pass --commit to apply" unless commit
