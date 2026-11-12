module Api
  module V1
    class DraftSerializer < BaseSerializer
      PRELOAD = %i[topic sender_alias created_via_token last_edited_via_token].freeze
      NOT_SET_UP = "the mailing list is not set up for sending".freeze
      NOT_CONFIGURED = "sending is not configured in this environment".freeze

      def self.brief_list(records, context, **extras)
        super(records, context, files: files_of(records).group_by(&:outgoing_draft_id), **extras)
      end

      # without the content
      def self.files_of(drafts)
        return [] if drafts.empty?

        DraftAttachment.where(outgoing_draft_id: drafts.map(&:id))
                       .select(:id, :outgoing_draft_id, :file_name, :content_type, :byte_size).order(:id).to_a
      end

      def brief
        fields({}, {})
      end

      def full
        fields({ body: record.body }, recipients)
      end

      private

      def fields(text, recipients)
        {
          id: record.id,
          url: api_url("/drafts/#{record.id}"),
          html_url: html_url,
          state: state,
          topic: topic_ref(record.topic),
          reply_to_message_id: record.reply_to_message_id,
          subject: record.subject,
          **text,
          sender: { name: record.sender_alias.name, email: record.sender_alias.email },
          **recipients,
          attachments: files.map { |file| file_ref(file) },
          last_send_error: record.last_send_error.presence,
          created_via: token_ref(record.created_via_token),
          last_edited_via: token_ref(record.last_edited_via_token),
          sent_message_id: record.sent_message_id,
          sent_at: record.sent_at,
          created_at: record.created_at,
          updated_at: record.updated_at
        }
      end

      # where the site shows it: the composer under the message, or the page of the sent mail
      def html_url
        return site_url(routes.draft_path(record.id)) if record.sent?

        site_url(routes.topic_path(record.topic_id, anchor: "message-#{record.reply_to_message_id}"))
      end

      def state
        return "in_progress" if record.idle? && !record.failed?

        record.failed? ? "failed" : record.status
      end

      def files
        extras[:files] ? extras[:files].fetch(record.id, []) : self.class.files_of([ record ])
      end

      def file_ref(file)
        { id: file.id, file_name: file.file_name, content_type: file.content_type.presence, byte_size: file.byte_size }
      end

      def token_ref(token)
        token && { token_name: token.name }
      end

      # the errors of the resolver are not passed on: they may name addresses and settings
      def recipients
        found = Outgoing::RecipientResolver.for(record)
        { recipients: { to: found.to, cc: found.cc }, recipients_error: nil }
      rescue Outgoing::RecipientResolver::MissingPostAddressError
        { recipients: nil, recipients_error: NOT_SET_UP }
      rescue Outgoing::RecipientResolver::MissingDevOverrideError, Outgoing::RecipientResolver::RealListAddressInDevError
        { recipients: nil, recipients_error: NOT_CONFIGURED }
      end
    end
  end
end
