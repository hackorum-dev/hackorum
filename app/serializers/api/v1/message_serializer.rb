module Api
  module V1
    class MessageSerializer < BaseSerializer
      BODIES = %w[none text full].freeze
      DEFAULT_BODY = "text".freeze
      COLUMNS = %w[
        id topic_id sender_id sender_person_id reply_to_id message_id subject created_at state is_patch_submission
      ].freeze
      PRELOAD = [ :sender, { sender_person: PersonSerializer::PRELOAD } ].freeze

      # the columns the rows need: the body only when it is shown
      def self.load(relation, body:)
        columns = body == "none" ? COLUMNS : COLUMNS + [ "body" ]
        relation.select(columns.map { |name| Message.arel_table[name] }).preload(PRELOAD)
      end

      def self.brief_list(records, context, **extras)
        super(records, context, page_data: MessagePageData.new(records, user: context.user), **extras)
      end

      def brief
        {
          id: record.id,
          url: api_url("/messages/#{record.id}"),
          html_url: message_html_url(record),
          topic_id: record.topic_id,
          number: page_data.number(record.id),
          rfc_message_id: record.message_id,
          subject: record.subject,
          created_at: record.created_at,
          state: record.state,
          sender: PersonSerializer.new(record.sender_person, context).brief,
          sender_alias: { name: record.sender.name, email: record.sender.email },
          reply_to_id: record.reply_to_id,
          depth: page_data.depth(record.id),
          is_patch_submission: record.is_patch_submission,
          body: body,
          attachments: AttachmentSerializer.brief_list(page_data.attachments(record.id), context),
          me: page_data.me(record.id)
        }
      end

      def full
        brief.merge(topic: topic_ref(record.topic))
      end

      private

      def page_data
        @page_data ||= extras[:page_data] || MessagePageData.new([ record ], user: context.user)
      end

      def body
        case extras.fetch(:body, DEFAULT_BODY)
        when "none" then nil
        when "full" then record.body
        else MessageBodyText.strip_quotes(record.body)
        end
      end
    end
  end
end
