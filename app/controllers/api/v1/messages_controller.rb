module Api
  module V1
    class MessagesController < BaseController
      include TopicLookup

      RFC_MESSAGE_ID_LIMIT = 998

      query_params :body, paged: true, on: :index
      query_params :body, on: :show
      query_params :rfc_message_id, :body, on: :lookup

      def index
        topic = find_topic!(params[:id])
        body = body_mode
        messages, next_cursor = paginate(topic.messages, columns: %w[messages.created_at messages.id],
                                                         direction: :asc) do |page|
          MessageSerializer.load(page, body: body)
        end
        render_page(MessageSerializer.brief_list(messages, context, body: body), next_cursor)
      end

      def show
        render_message(Message.where(id: path_param(:id)))
      end

      def lookup
        given = string_param(:rfc_message_id, max: RFC_MESSAGE_ID_LIMIT).to_s.strip
        bare = given.delete_prefix("<").delete_suffix(">")
        raise Api::InvalidParameter, "rfc_message_id is required" if bare.blank?

        render_message(Message.in_order_of(:message_id, [ given, bare, "<#{bare}>" ].uniq))
      end

      private

      def body_mode
        value = string_param(:body)
        return MessageSerializer::DEFAULT_BODY if value.nil?
        return value if MessageSerializer::BODIES.include?(value)

        raise Api::InvalidParameter, "body must be one of #{MessageSerializer::BODIES.join(', ')}"
      end

      def render_message(relation)
        body = body_mode
        message = MessageSerializer.load(relation, body: body).preload(:topic).first
        raise ActiveRecord::RecordNotFound unless message

        render json: MessageSerializer.new(message, context, body: body).full
      end
    end
  end
end
