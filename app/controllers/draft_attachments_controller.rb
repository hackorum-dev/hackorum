class DraftAttachmentsController < ApplicationController
  before_action :require_authentication
  before_action :set_draft
  before_action :reject_sent_drafts, except: :show

  def show
    attachment = @draft.draft_attachments.find(params[:id])
    type = attachment.content_type.to_s.strip.downcase.start_with?("text/") ? "text/plain; charset=utf-8" : "application/octet-stream"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Cache-Control"] = "private, no-store"
    send_data attachment.decoded_body.to_s, filename: Drafts::AttachmentAdder.file_name(attachment.file_name),
                                            type: type, disposition: "attachment"
  end

  def create
    uploads = Array(params[:files]).select { |f| f.respond_to?(:read) && f.size.positive? }
    return render_busy if @draft.sending?

    # sizes first, so an oversized pick is never read into memory
    total = @draft.attachment_bytes + uploads.sum(&:size)
    return render_too_large(total) if total > OutgoingDraft::MAX_ATTACHMENT_BYTES

    files = uploads.map { |f| { name: f.original_filename, content_type: f.content_type, bytes: f.read } }
    result = Drafts::AttachmentAdder.call(draft: @draft, files: files)
    return render_too_large(result.total) if result.too_large?
    return render_busy unless result.added?

    render_list
  end

  def destroy
    idle = with_idle_draft do
      @draft.draft_attachments.find(params[:id]).destroy!
      @draft.touch
    end
    return render_busy unless idle

    render_list
  end

  private

  def set_draft
    @draft = current_user.outgoing_drafts.find(params[:draft_id])
  end

  def reject_sent_drafts
    render_list(error: "This message has already been sent.", status: :unprocessable_entity) if @draft.sent?
  end

  def render_too_large(total)
    render_list(error: "Attachments would total #{helpers.attachment_mb(total)}, " \
                       "limit is #{helpers.attachment_mb(OutgoingDraft::MAX_ATTACHMENT_BYTES)}",
                status: :unprocessable_entity)
  end

  def render_busy
    render_list(error: "Sending in progress, attachments are read-only", status: :conflict)
  end

  # send_now flips the status under the same lock, so the mail and the stored message see the same files
  def with_idle_draft
    @draft.with_lock do
      next false unless @draft.idle?
      yield
      true
    end
  end

  def render_list(error: nil, status: :ok)
    render turbo_stream: turbo_stream.replace("draft-attachments-#{@draft.id}",
                                              partial: "drafts/attachments",
                                              locals: { draft: @draft, error: error }),
           status: status
  end
end
