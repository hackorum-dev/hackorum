#!/usr/bin/env ruby
# frozen_string_literal: true

# Fills feed_events from the records: messages, patchsets, branches, finished CI runs.
# Run once right after the deploy, before clients poll: the rows show up in the
# feed at once. Every event of the window that the feed lacks is added, at the
# time it happened. When the ids then do not follow those times, as with events
# recorded since the deploy, the whole table is renumbered in time order: all
# rows get new ids, and a client that polled before gets 410 and starts over
# with a since duration. Safe to run again: a run that died is finished by the
# next one, and a run with nothing to do writes nothing. It also adds an event
# lost to a crash between a writer's commit and the insert of its row.

require "optparse"

options = { days: 90, dry_run: false }

OptionParser.new do |o|
  o.banner = "Usage: ruby script/backfill_feed_events.rb [options]"
  o.on("--days N", Integer, "how far back to go (default #{options[:days]}, the retention of the feed)") do |v|
    options[:days] = v
  end
  o.on("--dry-run", "count only, write nothing") { options[:dry_run] = true }
end.parse!

require_relative "../config/environment"

def line(counts)
  return "nothing" if counts.empty?

  parts = FeedEvent::TYPES.filter_map { |type| "#{type} #{counts[type]}" if counts[type] }
  "#{counts.values.sum} (#{parts.join(', ')})"
end

def stamp(time)
  time.utc.strftime("%Y-%m-%d %H:%M:%S")
end

begin
  backfill = FeedEvents::Backfill.new(**options)
rescue ArgumentError => e
  abort e.message
end

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
result = backfill.call do |from, counts|
  puts "  #{from.utc.strftime('%Y-%m-%d %H:%M')}  +#{counts.values.sum}"
end
seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

puts "dry run, nothing written" if result.dry_run
puts "window: #{stamp(result.from)} .. #{stamp(result.to)} UTC (#{options[:days]} days)"
puts "#{result.dry_run ? 'would add' : 'added'} #{line(result.added)}"
if result.renumbered.positive?
  puts "#{result.dry_run ? 'would renumber' : 'renumbered'} all #{result.renumbered} events in time order: " \
       "they have new ids, positions handed out before answer 410"
else
  puts result.dry_run ? "no renumbering needed" : "ids follow the time order, nothing renumbered"
end
puts "feed_events now holds #{FeedEvent.count} rows"
puts format("took %.1fs", seconds)
