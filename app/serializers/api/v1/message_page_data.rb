module Api
  module V1
    # What message rows need besides the messages, loaded once for all of them.
    class MessagePageData
      def initialize(messages, user: nil)
        @user = user
        @ids = messages.map(&:id)
        @topics = messages.to_h { |message| [ message.id, message.topic_id ] }
        @topic_ids = @topics.values.uniq
        @depths = {}
      end

      def attachments(message_id)
        attachments_by_message.fetch(message_id, [])
      end

      # the user's own state on a message, nil without a user
      def me(message_id)
        return unless @user

        ranges = read_ranges.fetch(@topics[message_id], [])
        { read: ranges.any? { |first, last| message_id.between?(first, last) } }
      end

      # 1-based position in the thread
      def number(message_id)
        thread
        @numbers[message_id]
      end

      # replies above the message inside its topic; in a reply loop
      # the earliest message of the loop counts as the root
      def depth(message_id)
        return @depths[message_id] if @depths.key?(message_id)

        parents = thread
        path = []
        positions = {}
        current = message_id
        while current && !@depths.key?(current) && !positions.key?(current)
          positions[current] = path.size
          path << current
          parent = parents[current]
          current = parents.key?(parent) ? parent : nil
        end
        loop_depths(path.slice!(positions[current]..)) if positions.key?(current)

        depth = current ? @depths[current] + 1 : 0
        path.reverse_each do |id|
          @depths[id] = depth
          depth += 1
        end
        @depths[message_id]
      end

      private

      # members in reply order: each one replies to the next, the last to the first
      def loop_depths(members)
        root = members.index(members.min_by { |id| @numbers[id] })
        members.rotate(root).each_with_index do |id, position|
          @depths[id] = position.zero? ? 0 : members.size - position
        end
      end

      def attachments_by_message
        @attachments_by_message ||= @ids.empty? ? {} : Attachment
          .metadata.where(message_id: @ids).order(:id).group_by(&:message_id)
      end

      # topic id => [ first, last ] pairs
      def read_ranges
        @read_ranges ||= @topic_ids.empty? ? {} : MessageReadRange
          .where(user_id: @user.id, topic_id: @topic_ids)
          .pluck(:topic_id, :range_start_message_id, :range_end_message_id)
          .each_with_object({}) { |(topic_id, first, last), ranges| (ranges[topic_id] ||= []) << [ first, last ] }
      end

      # id => reply_to_id of every message of the topics
      def thread
        @thread ||= begin
          @numbers = {}
          rows = @topic_ids.empty? ? [] : ThreadNumber.of(@topic_ids).pluck(:id, :reply_to_id, ThreadNumber::SQL)
          rows.each_with_object({}) do |(id, reply_to_id, number), parents|
            @numbers[id] = number
            parents[id] = reply_to_id
          end
        end
      end
    end
  end
end
