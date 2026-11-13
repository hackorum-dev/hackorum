#!/usr/bin/env ruby
# frozen_string_literal: true

# Join replies that were ingested before their parent.
#
# Such a reply has reply_to_message_id set but no reply_to_id, and sits in a
# topic of its own. This links it to the parent and merges its topic into the
# parent's topic.
#
# Usage:
#   ruby script/repair_split_threads.rb                      # dry run, report only
#   ruby script/repair_split_threads.rb --apply              # link and merge
#   ruby script/repair_split_threads.rb --since=2025-01-01   # only replies dated on/after
#   ruby script/repair_split_threads.rb --verbose            # list every pair

require_relative "../config/environment"

apply = ARGV.include?("--apply")
verbose = ARGV.include?("--verbose")
since = ARGV.filter_map { |a| a[/\A--since=(.+)\z/, 1] }.first
since = Time.zone.parse(since) if since

pairs = Message.joins("JOIN messages parent ON parent.message_id = messages.reply_to_message_id")
               .where(reply_to_id: nil)
               .where("parent.id <> messages.id")
pairs = pairs.where("messages.created_at >= ?", since) if since
rows = pairs.order("messages.id").pluck("messages.id", "parent.id")

puts "#{rows.size} replies with a parent that arrived later#{" (since #{since.to_date})" if since}"
puts "(dry run - use --apply to change anything)" unless apply

stats = Hash.new(0)
by_year = Hash.new(0)

rows.each do |child_id, parent_id|
  child = Message.find(child_id)
  parent = Message.find(parent_id)
  next stats[:already_linked] += 1 if child.reply_to_id

  split = child.topic_id != parent.topic_id
  outcome =
    if OrphanReplyLinker.descends_from?(parent, child)
      :cycle_skipped
    elsif !apply
      split ? :would_merge : :would_link
    elsif OrphanReplyLinker.link(child, parent)
      split ? :merged : :linked
    else
      :failed
    end

  stats[outcome] += 1
  by_year[child.created_at.year] += 1 if split
  if verbose || outcome == :failed
    puts "#{outcome}: message #{child.id} (topic #{child.topic_id}) -> #{parent.id} (topic #{parent.topic_id}) #{child.subject.to_s[0, 60]}"
  end
end

stats.sort.each { |k, v| puts "#{k}: #{v}" }
puts "split topics by year: #{by_year.sort.map { |y, n| "#{y}=#{n}" }.join(' ')}" if by_year.any?
