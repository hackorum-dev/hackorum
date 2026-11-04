#!/usr/bin/env ruby
# frozen_string_literal: true

# Re-applies the committer-as-reviewer rule to stored verdicts: a trailer
# reviewer who also committed the change counts as having reviewed the final
# version. New ingests do this on the way in (Lineage::CommitterReviews); this
# fixes rows written before that existed.
#
# Prints what it would change and writes nothing unless --commit is given.
require_relative "../config/environment"

commit = ARGV.include?("--commit")

changed = 0
CommitVerdict.where(extra: false).where.not(reviews: nil).includes(:commit).find_each do |verdict|
  rows = verdict.reviews
  next if rows.blank?

  commits = [ verdict.commit, *Commit.where(cherry_picked_from_sha: verdict.commit.sha) ]
  people = CommitPerson.parsed.where(commit_id: commits.map(&:id), role: [ "reviewer", CommitPerson::COMMITTER ])
                       .includes(person: :default_alias)
  names = Lineage::CommitterReviews.names(commits, people)
  next if names.empty?

  fixed = Lineage::CommitterReviews.apply(rows, names, verdict.source_message_id)
  next if fixed == rows

  changed += 1
  who = fixed.zip(rows).select { |a, b| a != b }.map { |a, _| a["reviewer"] }
  puts "verdict #{verdict.id} topic #{verdict.topic_id} #{verdict.commit.sha[0, 10]}: #{who.join(', ')}"
  verdict.update!(reviews: fixed, **Lineage::CommitterReviews.counts(fixed)) if commit
end

puts "#{changed} verdicts #{commit ? 'updated' : 'to update'}"
puts "dry run, nothing written - pass --commit to apply" unless commit
