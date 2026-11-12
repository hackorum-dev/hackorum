module Api
  module V1
    # One user's own state on the topics of one page, five queries for the page.
    class TopicMeData
      def initialize(user, topics)
        @user = user
        @ids = topics.map(&:id)
      end

      def for(topic)
        read_count = read_counts[topic.id].to_i
        {
          starred: starred_ids.include?(topic.id),
          ignored: ignored_ids.include?(topic.id),
          status: status(topic, read_count),
          read_count: read_count,
          unread_count: [ topic.message_count - read_count, 0 ].max,
          note_count: note_counts[topic.id].to_i
        }
      end

      # first message in thread order outside the read ranges
      def first_unread_message_id(topic)
        Message.where(topic_id: topic.id).where(<<~SQL.squish, @user.id, topic.id).order(:created_at, :id).pick(:id)
          NOT EXISTS (
            SELECT 1 FROM message_read_ranges ranges
            WHERE ranges.user_id = ? AND ranges.topic_id = ?
              AND ranges.range_start_message_id <= messages.id
              AND ranges.range_end_message_id >= messages.id
          )
        SQL
      end

      private

      # same answers, in the same order, as TopicListPersonalization#compute_status
      def status(topic, read_count)
        aware = aware_ids.include?(topic.id)
        aware_before = @user.aware_before
        return "new" unless aware || read_count.positive? || aware_before
        return "read" if topic.message_count.positive? && read_count >= topic.message_count
        return "reading" if read_count.positive?
        return "aware" if aware_before && topic.last_message_at && topic.last_message_at <= aware_before

        aware ? "aware" : "new"
      end

      def aware_ids
        @aware_ids ||= own(ThreadAwareness).pluck(:topic_id).to_set
      end

      def read_counts
        @read_counts ||= own(MessageReadRange).group(:topic_id).sum(:message_count)
      end

      def starred_ids
        @starred_ids ||= own(TopicStar).pluck(:topic_id).to_set
      end

      def ignored_ids
        @ignored_ids ||= own(TopicIgnore).pluck(:topic_id).to_set
      end

      def note_counts
        @note_counts ||= @ids.empty? ? {} : Note.visible_to(@user).active.where(topic_id: @ids).group(:topic_id).count
      end

      def own(model)
        @ids.empty? ? model.none : model.where(user_id: @user.id, topic_id: @ids)
      end
    end
  end
end
