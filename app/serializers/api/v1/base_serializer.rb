module Api
  module V1
    # Subclasses define `brief` and, when they have a detail shape, `full`.
    # `extras` is what the rows of one page share. A subclass names the
    # associations it reads in PRELOAD.
    class BaseSerializer
      attr_reader :record, :context, :extras

      delegate :site_url, :api_url, :routes, to: :context

      def self.brief_list(records, context, **extras)
        records.map { |record| new(record, context, **extras).brief }
      end

      def initialize(record, context, **extras)
        @record = record
        @context = context
        @extras = extras
      end

      def full
        brief
      end

      private

      def helpers
        ApplicationController.helpers
      end

      def topic_ref(topic)
        TopicSerializer.new(topic, context).ref
      end

      def message_html_url(message)
        site_url(routes.topic_path(message.topic_id, anchor: "message-#{message.id}"))
      end
    end
  end
end
