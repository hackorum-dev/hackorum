namespace :classify do
  desc "Create the classify bot user and global tags"
  task setup: :environment do
    bot = Classify::Setup.call!
    puts "bot user ##{bot.id} #{bot.username}"
  end

  desc "Delete failed and timed out classification runs so the queue picks the topics again"
  task :requeue_failed, [ :topic_id ] => :environment do |_, args|
    runs = ClassificationRun.where(status: %w[failed timeout])
    runs = runs.where(topic_id: args[:topic_id]) if args[:topic_id].present?
    puts runs.delete_all
  end
end
