module Api
  module V1
    # Drafts of replies. They are written here and sent on the site only.
    class DraftsController < BaseController
      SUBJECT_LIMIT = 998
      BODY_BYTES = 1.megabyte
      QUOTE_BYTES = 100.kilobytes
      STATES = %w[in_progress failed sending sent].freeze
      SUBJECT = { type: :string, max_length: SUBJECT_LIMIT, blank: false, single_line: true }.freeze
      BODY = { type: :string, max_bytes: BODY_BYTES }.freeze
      NO_PARENT = "reply_to_message_id is required: drafts that start a thread are not supported yet".freeze

      before_action :require_token
      around_action :with_lock_timeout, only: %i[update destroy]

      query_params :state, paged: true, on: :index
      cursor_per_caller on: :index
      request_body on: :create, reply_to_message_id: { type: :id, required: NO_PARENT }, subject: SUBJECT, body: BODY,
                                quote: { type: :string, max_bytes: QUOTE_BYTES }
      request_body on: :update, subject: SUBJECT, body: BODY, updated_at: { type: :timestamp }

      def index
        drafts = in_state(current_user.outgoing_drafts, state_param)
        rows, next_cursor = paginate(drafts, columns: %w[outgoing_drafts.updated_at outgoing_drafts.id]) do |page|
          page.preload(DraftSerializer::PRELOAD)
        end
        render_page(DraftSerializer.brief_list(rows, context), next_cursor)
      end

      def show
        render_draft(current_user.outgoing_drafts.find(params[:id]))
      end

      def create
        fields = body_fields
        parent = Message.find(fields.fetch("reply_to_message_id"))
        result = Drafts::Creator.call(user: current_user, reply_to_message: parent, token: current_token, max_body_bytes: BODY_BYTES,
                                      **fields.slice("subject", "body", "quote").symbolize_keys)
        render_draft(result.draft, status: result.created? ? :created : :ok)
      rescue Drafts::Creator::NoSendIdentity
        render_error :no_send_identity, "The account has no Gmail identity that may send, connect one on the site"
      rescue Drafts::Creator::NoSenderAlias
        render_error :no_send_identity, "The address of the Gmail identity that may send is not an address of the account"
      rescue Drafts::Creator::LimitReached
        render_error :draft_limit, "The account has #{Drafts::TokenLimits::ACTIVE_DRAFTS} drafts that are not sent, " \
                                   "send or delete some of them first"
      rescue Drafts::Creator::BodyTooLarge
        render_error :invalid_body, "body with the quote is too long, at most #{BODY_BYTES} bytes"
      end

      def update
        draft = locked_draft
        fields = body_fields
        return render_error(:invalid_body, "The draft was sent and cannot be changed") if draft.sent?
        return render_error(:conflict, "The draft is being sent") if draft.sending?
        return render_error(:conflict, "The draft changed since the updated_at given") if stale?(draft, fields["updated_at"])

        draft.assign_attributes(fields.slice("subject", "body"))
        draft.last_edited_via_token = current_token if draft.changed?
        return render_error(:invalid_body, draft.errors.full_messages.first || "The draft cannot be saved") unless draft.save

        render_draft(draft)
      end

      def destroy
        draft = locked_draft
        return render_error(:unprocessable_content, "The draft was sent and cannot be deleted") if draft.sent?
        return render_error(:conflict, "The draft is being sent") if draft.sending?

        draft.destroy!
        head :no_content
      end

      private

      # locked: the site may start to send it at the same time
      def locked_draft
        current_user.outgoing_drafts.lock.find(params[:id])
      end

      def render_draft(draft, status: :ok)
        render json: DraftSerializer.new(draft, context).full, status: status
      end

      # compared at the precision the API prints
      def stale?(draft, seen)
        seen && draft.updated_at.floor(3) != seen.floor(3)
      end

      def state_param
        value = string_param(:state)
        return value if value.nil? || STATES.include?(value)

        raise Api::InvalidParameter, "state must be one of #{STATES.join(', ')}"
      end

      def in_state(drafts, state)
        case state
        when "in_progress" then drafts.idle.where(last_send_error: [ nil, "" ])
        when "failed" then drafts.idle.where.not(last_send_error: [ nil, "" ])
        when "sending" then drafts.sending
        when "sent" then drafts.sent
        else drafts
        end
      end
    end
  end
end
