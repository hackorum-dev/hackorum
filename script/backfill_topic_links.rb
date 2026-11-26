# usage: bin/rails runner script/backfill_topic_links.rb
ids = CommitTopic.group(:commit_id).having("count(*) > 1").pluck(:commit_id)
ids.each_slice(1000).with_index { |batch, i| TopicLinks.sync_commits!(batch); puts "batch #{i + 1}" }
ids = CommitfestPatchTopic.group(:commitfest_patch_id).having("count(*) > 1").pluck(:commitfest_patch_id)
ids.each_slice(1000).with_index { |batch, i| TopicLinks.sync_commitfest!(batch); puts "commitfest batch #{i + 1}" }
done = 0
Commit.where("body ~ '[0-9a-f]{8}'").in_batches(of: 2000) do |batch|
  TopicLinks.sync_fixes!(batch.ids)
  done += batch.ids.size
  puts "fixes: #{done} commits"
end
done = 0
Message.where("body ~* ? OR body ~ ?", 'postgr\.es/m/|message-id/', '[0-9a-f]{8}').in_batches(of: 2000) do |batch|
  TopicLinks.sync_mentions!(batch.ids)
  done += batch.ids.size
  puts "mentions: #{done} messages"
end
puts "topic_links: #{TopicLink.count}"
