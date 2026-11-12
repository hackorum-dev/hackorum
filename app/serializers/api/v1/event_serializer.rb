module Api
  module V1
    # A FeedEvent row of Api::EventFeed.
    class EventSerializer < BaseSerializer
      PAYLOADS = {
        FeedEvent::MESSAGE_RECEIVED => :message,
        FeedEvent::PATCHSET_POSTED => :patchset,
        FeedEvent::BRANCH_CREATED => :branch,
        FeedEvent::CI_COMPLETED => :ci_run
      }.freeze

      # an event whose record went away since the page was read is left out
      def self.brief_list(events, context)
        page_data = EventPageData.new(events, context)
        events.filter_map { |event| new(event, context, page_data: page_data).brief }
      end

      def brief
        payload = page_data.payload(record)
        topic = page_data.topic(record)
        return unless payload && topic

        author = page_data.author(record)
        {
          id: record.id,
          type: record.event_type,
          occurred_at: record.occurred_at,
          recorded_at: record.created_at,
          topic: topic_ref(topic),
          author: author && PersonSerializer.new(author, context).brief,
          PAYLOADS.fetch(record.event_type) => payload
        }
      end

      private

      def page_data
        extras.fetch(:page_data)
      end
    end
  end
end
