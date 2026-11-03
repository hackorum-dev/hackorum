#!/usr/bin/env ruby
# frozen_string_literal: true

# Applies the "split" rows of a person_splits.csv written by
# script/person_split_report.rb through PersonSplitService, then relinks
# commit credits. Dry run unless --apply. Delete rows you do not want first.
#
#   ruby script/person_split_apply.rb tmp/person_splits.csv [--person ID] [--apply]

require_relative "../config/environment"
require "csv"
require "optparse"

options = { apply: false, persons: nil }
OptionParser.new do |o|
  o.banner = "Usage: ruby script/person_split_apply.rb CSV [--person ID] [--apply]"
  o.on("--person ID", Integer, "only this person, repeatable") { |v| (options[:persons] ||= []) << v }
  o.on("--apply", "split for real") { options[:apply] = true }
end.parse!

path = ARGV.shift or abort "error: csv path missing"
done = 0
failed = 0

CSV.foreach(path, headers: true) do |row|
  next unless row["action"] == "split"
  next if options[:persons] && !options[:persons].include?(row["person"].to_i)

  person = Person.find_by(id: row["person"])
  emails = row["emails"].split
  membership_ids = row["membership_ids"].to_s.split.map(&:to_i)
  label = "#{row['person']} -> new person: #{row['name']} (#{emails.join(', ')})"
  label += ", memberships #{membership_ids.join(' ')}" if membership_ids.any?

  unless person
    puts "skip  #{label}: person gone"
    failed += 1
    next
  end

  unless options[:apply]
    puts "would #{label}"
    done += 1
    next
  end

  result = PersonSplitService.new(person: person, emails: emails, membership_ids: membership_ids).call
  if result.success?
    puts "done  #{label} = #{result.person.id}"
    done += 1
  else
    puts "fail  #{label}: #{result.error}"
    failed += 1
  end
end

puts "#{options[:apply] ? 'split' : 'would split'} #{done}, failed #{failed}"

if options[:apply] && done.positive?
  puts "relinking commit credits"
  CommitImport::Importer.new(repository: nil, logger: Logger.new($stdout)).relink_people!
end
