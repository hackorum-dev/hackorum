module Api
  module V1
    # Takes rows of Attachment.metadata: the body is not loaded.
    class AttachmentSerializer < BaseSerializer
      def brief
        {
          id: record.id,
          message_id: record.message_id,
          file_name: record.file_name,
          content_type: record.content_type.presence,
          byte_size: record.byte_size,
          is_patch: record.patch_submission_candidate?,
          url: api_url("/attachments/#{record.id}"),
          content_url: api_url("/attachments/#{record.id}/content")
        }
      end
    end
  end
end
