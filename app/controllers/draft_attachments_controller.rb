class DraftAttachmentsController < ApplicationController
  before_action :require_authentication
  before_action :set_draft
  before_action :reject_sent_drafts

  def create
    files = Array(params[:files]).select { |f| f.respond_to?(:read) && f.size.positive? }
    error = nil

    idle = with_idle_draft do
      total = @draft.attachment_bytes + files.sum(&:size)
      if total > OutgoingDraft::MAX_ATTACHMENT_BYTES
        error = "Attachments would total #{helpers.attachment_mb(total)}, " \
                "limit is #{helpers.attachment_mb(OutgoingDraft::MAX_ATTACHMENT_BYTES)}"
      else
        files.each do |f|
          @draft.draft_attachments.create!(
            file_name: upload_name(f),
            content_type: f.content_type.presence || "application/octet-stream",
            body: Base64.encode64(f.read),
            byte_size: f.size
          )
        end
      end
    end
    return render_busy unless idle

    render_list(error: error, status: error ? :unprocessable_entity : :ok)
  end

  def destroy
    idle = with_idle_draft { @draft.draft_attachments.find(params[:id]).destroy! }
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

  def upload_name(file)
    File.basename(file.original_filename.to_s.scrub("_")).gsub(/[\x00-\x1f"\\]/, "_").presence || "attachment"
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
