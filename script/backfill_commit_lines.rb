#!/usr/bin/env ruby
# frozen_string_literal: true

# Fills commits.lines_added / lines_removed for rows imported before the
# columns existed. Needs the postgres mirror (HACKORUM_PG_REPO), so it runs
# where the importer runs, not from an arbitrary shell.
require_relative "../config/environment"

repo = CommitImport::Repository.new
abort("no git mirror at #{repo.path}") unless File.directory?(repo.path) && !Dir.empty?(repo.path)
repo.sync!(fetch: false)
conn = ActiveRecord::Base.connection

scope = Commit.where(lines_added: nil)
total = scope.count
done = 0
puts "backfilling #{total} commits"

scope.select(:id, :sha).find_in_batches(batch_size: 1000) do |batch|
  rows = repo.commits(batch.map(&:sha)).map do |record|
    "(#{conn.quote(record.sha)}, #{record.lines_added.to_i}, #{record.lines_removed.to_i})"
  end
  if rows.any?
    conn.execute(<<~SQL)
      UPDATE commits SET lines_added = v.added, lines_removed = v.removed
      FROM (VALUES #{rows.join(',')}) AS v(sha, added, removed)
      WHERE commits.sha = v.sha
    SQL
  end
  done += batch.size
  puts "#{done}/#{total} (#{rows.size} updated)"
end
puts "still null: #{Commit.where(lines_added: nil).count}"
