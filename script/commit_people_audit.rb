#!/usr/bin/env ruby
# frozen_string_literal: true

# Read-only. Re-parses stored commit bodies with the current TrailerParser
# and prints every commit whose trailer people would change. Run after a
# parser change, review, then fix with:
#
#   ruby script/commit_import.rb --reparse
#
#   ruby script/commit_people_audit.rb            # diff per commit + summary
#   ruby script/commit_people_audit.rb --summary  # summary only

require_relative "../config/environment"

summary_only = ARGV.include?("--summary")

def fmt(row)
  role, name, email = row
  [ role.ljust(11), name, email && "<#{email}>" ].compact.join(" ")
end

commits = 0
removed = 0
added = 0

Commit.select(:id, :sha, :subject, :body).find_in_batches(batch_size: 1000) do |batch|
  stored = CommitPerson.where(commit_id: batch.map(&:id))
                       .where.not(role: CommitPerson::COMMITTER)
                       .pluck(:commit_id, :role, :raw_name, :raw_email)
                       .group_by(&:first)

  batch.each do |commit|
    old_rows = (stored[commit.id] || []).map { |row| row.drop(1) }.uniq.sort_by(&:to_s)
    new_rows = CommitImport::TrailerParser.new(subject: commit.subject, body: commit.body)
                                          .people.map { |p| [ p.role, p.name, p.email ] }
                                          .uniq.sort_by(&:to_s)
    gone = old_rows - new_rows
    fresh = new_rows - old_rows
    next if gone.empty? && fresh.empty?

    commits += 1
    removed += gone.size
    added += fresh.size
    next if summary_only

    puts "#{commit.sha[0, 12]} #{commit.subject}"
    gone.each { |row| puts "  - #{fmt(row)}" }
    fresh.each { |row| puts "  + #{fmt(row)}" }
  end
end

puts "#{commits} commits affected, #{removed} rows removed, #{added} rows added"
