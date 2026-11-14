# usage: bin/rails runner script/backfill_topic_links.rb
ids = CommitTopic.group(:commit_id).having("count(*) > 1").pluck(:commit_id)
ids.each_slice(1000).with_index { |batch, i| TopicLinks.sync_commits!(batch); puts "batch #{i + 1}" }
puts "topic_links: #{TopicLink.count}"
