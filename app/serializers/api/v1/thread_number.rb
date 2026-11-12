module Api
  module V1
    # 1-based position in the thread; a window, so filter the rows outside of the query
    module ThreadNumber
      SQL = Arel.sql("row_number() OVER (PARTITION BY messages.topic_id ORDER BY messages.created_at, messages.id)")

      def self.of(topic_ids)
        Message.where(topic_id: topic_ids)
      end
    end
  end
end
