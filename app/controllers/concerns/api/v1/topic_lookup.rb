module Api
  module V1
    module TopicLookup
      extend ActiveSupport::Concern

      class Merged < StandardError
        attr_reader :target

        def initialize(target)
          @target = target
          super("merged into topic #{target.id}")
        end
      end

      TOPIC_PATH = %r{\A/api/v1/topics/[^/]+}

      # the same resource on another topic; the host is ours, not the request's
      def self.moved_url(context, path:, query:, id:)
        rest = path.to_s.match?(TOPIC_PATH) ? path.to_s.sub(TOPIC_PATH, "") : ""
        url = context.api_url("/topics/#{id}#{rest}")
        query.present? ? "#{url}?#{query}" : url
      end

      included do
        rescue_from Merged do |e|
          location = TopicLookup.moved_url(context, path: request.path, query: request.query_string, id: e.target.id)
          head :moved_permanently, location: location
        end
      end

      private

      # digits are an id, anything else a slug
      def find_topic!(param, preload: nil)
        value = param.to_s
        raise ActiveRecord::RecordNotFound if value.include?("\0")

        topics = preload ? Topic.preload(preload) : Topic
        topic = value.match?(/\A\d+\z/) ? topics.find_by(id: value) : topics.find_by(slug: value.downcase)
        raise ActiveRecord::RecordNotFound unless topic
        return topic unless topic.merged?

        target = topic.final_topic
        raise ActiveRecord::RecordNotFound if target.merged?
        raise Merged, target
      end
    end
  end
end
