class AttachmentsController < ApplicationController
  def show
    attachment = Attachment.find(params[:id])
    data = attachment.decoded_body
    return head :not_found unless data

    filename = attachment.file_name.presence || "attachment-#{attachment.id}"
    content_type = attachment.content_type.presence || "application/octet-stream"

    send_data data, filename: filename, type: content_type, disposition: "attachment"
  end
end
