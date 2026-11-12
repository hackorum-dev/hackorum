module Api
  module V1
    # The files of a draft. Their content comes in as Base64 and is not given back.
    class DraftAttachmentsController < BaseController
      TEXT_LIMIT = 255
      TOKEN = '[A-Za-z0-9!#$&^_.+-]+'.freeze
      # as the document has it
      MEDIA_TYPE = format('^%<t>s/%<t>s( *; *%<t>s=(%<t>s|"[^"\\\\]*"))*$', t: TOKEN).freeze
      MEDIA_TYPE_FORMAT = /\A#{MEDIA_TYPE.delete_prefix('^').delete_suffix('$')}\z/
      WHITESPACE = " \t\n\v\f\r".freeze
      LINE = { type: :string, max_length: TEXT_LIMIT, blank: false, single_line: true }.freeze

      before_action :require_token
      around_action :with_lock_timeout

      request_body on: :create, file_name: { required: "file_name is required", **LINE }, content_type: LINE,
                                content_base64: { type: :string, required: "content_base64 is required", blank: false }

      def create
        draft = current_user.outgoing_drafts.lock.find(params[:id])
        upload = file
        return render_user_limit if over_user_limit?(draft, upload)

        result = Drafts::AttachmentAdder.call(draft: draft, files: [ upload ], token: current_token)
        return render_refusal(result) unless result.added?

        render_draft(draft, status: :created)
      end

      def destroy
        draft = current_user.outgoing_drafts.lock.find(params[:id])
        attachment = draft.draft_attachments.find(params[:attachment_id])
        return render_error(:unprocessable_content, "The draft was sent and cannot be changed") if draft.sent?
        return render_error(:conflict, "The draft is being sent") if draft.sending?

        attachment.destroy!
        draft.update!(last_edited_via_token: current_token, updated_at: Time.current)
        render_draft(draft)
      end

      private

      def render_draft(draft, status: :ok)
        render json: DraftSerializer.new(draft, context).full, status: status
      end

      # the lock is on this draft only: uploads to two drafts at once can pass the limit by one file
      def over_user_limit?(draft, upload)
        draft.idle? && Drafts::TokenLimits.attachment_bytes(current_user) + upload[:bytes].bytesize > Drafts::TokenLimits::ATTACHMENT_BYTES
      end

      def render_user_limit
        render_error :draft_limit, "The attachments of the drafts of the account that are not sent would be over " \
                                   "#{Drafts::TokenLimits::ATTACHMENT_BYTES} bytes, send or delete some of them first"
      end

      def render_refusal(result)
        return render_error(:invalid_body, "The draft was sent and cannot be changed") if result.sent?
        return render_error(:conflict, "The draft is being sent") if result.sending?

        render_error :invalid_body, "The attachments of the draft would be #{result.total} bytes, " \
                                    "the limit is #{OutgoingDraft::MAX_ATTACHMENT_BYTES} bytes"
      end

      def file
        fields = body_fields
        type = fields["content_type"]
        raise Api::RequestBody::Invalid, "content_type must be a media type, such as text/x-diff" if type && !type.match?(MEDIA_TYPE_FORMAT)

        { name: fields.fetch("file_name"), content_type: type, bytes: decoded(fields.fetch("content_base64")) }
      end

      # the line breaks of wrapped Base64 are taken out, nothing else is forgiven
      def decoded(content)
        Base64.strict_decode64(content.delete(WHITESPACE))
      rescue ArgumentError
        raise Api::RequestBody::Invalid, "content_base64 is not valid Base64"
      end
    end
  end
end
