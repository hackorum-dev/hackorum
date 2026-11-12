class PruneFeedEventsJob < ApplicationJob
  queue_as :default

  BATCH = 10_000

  def perform
    cutoff = Api::EventFeed::RETENTION.ago
    total = 0
    loop do
      batch = FeedEvent.where(created_at: ...cutoff).order(:created_at).limit(BATCH).select(:id)
      deleted = FeedEvent.where(id: batch).delete_all
      total += deleted
      break if deleted < BATCH
    end
    Rails.logger.info("pruned #{total} feed events older than #{cutoff.utc.iso8601}")
    total
  end
end
