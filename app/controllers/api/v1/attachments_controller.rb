module Api
  module V1
    class AttachmentsController < BaseController
      NAME_LENGTH = 200
      EXTENSION_LENGTH = 20
      TEXT_TYPE = "text/plain; charset=utf-8".freeze
      BINARY_TYPE = "application/octet-stream".freeze

      def show
        attachment = Attachment.metadata.find_by(id: path_param(:id))
        raise ActiveRecord::RecordNotFound unless attachment

        render json: AttachmentSerializer.new(attachment, context).brief
      end

      # never the stored type: the bytes are a download, text or not
      def content
        attachment = Attachment.find_by(id: path_param(:id))
        data = attachment&.decoded_body
        raise ActiveRecord::RecordNotFound if data.nil? || data.empty?

        response.headers["X-Content-Type-Options"] = "nosniff"
        send_data data, filename: download_name(attachment), disposition: "attachment",
                        type: attachment.text? ? TEXT_TYPE : BINARY_TYPE
      end

      private

      def download_name(attachment)
        name = attachment.file_name.to_s.scrub("").split(%r{[/\\]}).last.to_s.gsub(/[[:cntrl:]]/, "").strip
        name = shorten(name)
        name.blank? || name.match?(/\A\.+\z/) ? "attachment-#{attachment.id}" : name
      end

      def shorten(name)
        return name if name.length <= NAME_LENGTH

        extension = File.extname(name)
        extension = "" if extension.length > EXTENSION_LENGTH
        name.first(NAME_LENGTH - extension.length) + extension
      end
    end
  end
end
