#!/usr/bin/env ruby
# frozen_string_literal: true

# Applies merges from a person_merges.csv written by
# script/person_duplicates_report.rb, through PersonMergeService, so each one
# gets the same audit record as an admin UI merge. Dry run unless --apply.
# Delete rows you do not want from the csv first.
#
#   ruby script/person_merge_apply.rb tmp/person_merges.csv --admin you@example.com
#   ruby script/person_merge_apply.rb tmp/person_merges.csv --admin you@example.com --tier trivial --apply
#
# Afterwards, credit the now unambiguous names:
#
#   ruby script/commit_import.rb --relink

require_relative "../config/environment"
require "csv"
require "optparse"

options = { apply: false, tiers: nil, admin: nil }
OptionParser.new do |o|
  o.banner = "Usage: ruby script/person_merge_apply.rb CSV --admin EMAIL [--tier TIER] [--apply]"
  o.on("--admin EMAIL", "admin user recorded as the one merging") { |v| options[:admin] = v }
  o.on("--tier TIER", "only rows of this tier, repeatable") { |v| (options[:tiers] ||= []) << v }
  o.on("--apply", "merge for real") { options[:apply] = true }
end.parse!

path = ARGV.shift or abort "error: csv path missing"
admin = User.joins(person: :aliases).find_by("lower(aliases.email) = ?", options[:admin].to_s.downcase)
abort "error: no admin user for #{options[:admin].inspect}" unless admin&.admin?

done = 0
skipped = 0

CSV.foreach(path, headers: true) do |row|
  next if options[:tiers] && !options[:tiers].include?(row["tier"])

  label = "#{row['name']}: #{row['source_person']} (#{row['source_emails']}) -> #{row['target_person']}"
  source = Person.find_by(id: row["source_person"])
  target = Person.find_by(id: row["target_person"])
  service = PersonMergeService.new(source_person: source, target_person: target, merged_by: admin)

  if (error = service.validation_error)
    puts "skip  #{label}: #{error}"
    skipped += 1
    next
  end

  if options[:apply]
    result = service.call
    unless result.success?
      puts "fail  #{label}: #{result.error}"
      skipped += 1
      next
    end
  end

  puts "#{options[:apply] ? 'done ' : 'would'} #{label}"
  done += 1
end

puts "#{options[:apply] ? 'merged' : 'would merge'} #{done}, skipped #{skipped}"
