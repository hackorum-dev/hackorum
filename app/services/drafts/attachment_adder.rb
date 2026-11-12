module Drafts
  # Stores files on a draft, all of them or none.
  class AttachmentAdder
    DEFAULT_TYPE = "application/octet-stream".freeze
    MEDIA_TYPE = %r{\A[a-z0-9][a-z0-9!#$&^_.+-]{0,63}/[a-z0-9][a-z0-9!#$&^_.+-]{0,63}\z}
    CHARSETS = %w[utf-8 us-ascii iso-8859-1 iso-8859-15 windows-1252].freeze

    # total: the bytes the draft has, or would have had
    Result = Struct.new(:status, :total) do
      def added? = status == :added
      def too_large? = status == :too_large
      def sending? = status == :sending
      def sent? = status == :sent
    end

    def self.call(...)
      new(...).call
    end

    def self.file_name(raw)
      name = raw.to_s.dup.force_encoding(Encoding::UTF_8).scrub("_")
      name = File.basename(name).gsub(/[\p{Cf}\p{Zl}\p{Zp}]/, "").gsub(/[\p{Cc}"\\]/, "_").strip
      name.match?(%r{\A[.\/\p{Z}\s]*\z}) ? "attachment" : name
    end

    # type/subtype and at most a known charset: nothing that can change how a mail is put together
    def self.content_type(raw)
      type, *params = raw.to_s.dup.force_encoding(Encoding::UTF_8).scrub("").split(";").map { |piece| piece.strip.downcase }
      return DEFAULT_TYPE unless type&.match?(MEDIA_TYPE) && !type.start_with?("multipart/", "message/")

      charsets = params.filter_map { |param| param.delete_prefix("charset=").delete('"') if param.start_with?("charset=") }.uniq
      charsets.one? && CHARSETS.include?(charsets.first) ? "#{type}; charset=#{charsets.first}" : type
    end

    # files: hashes with name, content_type and bytes
    def initialize(draft:, files:, token: nil)
      @draft = draft
      @files = files
      @token = token
    end

    # under the lock a send takes, so the mail has the files the draft shows
    def call
      @draft.with_lock do
        next Result.new(:sent) if @draft.sent?
        next Result.new(:sending) unless @draft.idle?

        total = @draft.attachment_bytes + @files.sum { |file| file[:bytes].bytesize }
        next Result.new(:too_large, total) if total > OutgoingDraft::MAX_ATTACHMENT_BYTES

        store
        Result.new(:added, total)
      end
    end

    private

    def store
      return if @files.empty?

      @files.each do |file|
        @draft.draft_attachments.create!(
          file_name: self.class.file_name(file[:name]),
          content_type: self.class.content_type(file[:content_type]),
          body: Base64.encode64(file[:bytes]),
          byte_size: file[:bytes].bytesize
        )
      end
      # updated_at tells other clients that the draft changed
      @token ? @draft.update!(last_edited_via_token: @token, updated_at: Time.current) : @draft.touch
    end
  end
end
