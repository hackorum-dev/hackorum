require "securerandom"
require "mail"
require "set"

module Outgoing
  class MessageBuilder
    Result = Struct.new(:encoded, :message_id, :subject, :recipient,
                        keyword_init: true)
    DEFAULT_DOMAIN = "hackorum.dev"

    def self.new_message_id
      "<#{SecureRandom.uuid}@#{ENV.fetch('HACKORUM_OUTGOING_DOMAIN', DEFAULT_DOMAIN)}>"
    end

    def self.build(draft)
      recipients = RecipientResolver.for(draft)
      msg_id     = draft.rfc_message_id.presence || new_message_id

      from_addr = Mail::Address.new
      from_addr.address = draft.sender_alias.email
      from_addr.display_name = draft.sender_alias.name
      mail = Mail.new do
        from       from_addr.format
        to         recipients.to
        subject    draft.subject
        message_id msg_id
      end
      mail.cc = recipients.cc if recipients.cc.any?

      attachments = draft.draft_attachments.order(:id).to_a
      if attachments.empty?
        mail.body draft.body
        mail.content_type "text/plain; charset=UTF-8"
      else
        text = Mail::Part.new
        text.content_type "text/plain; charset=UTF-8"
        text.body draft.body
        mail.add_part text
        attachments.each do |a|
          mail.add_file(filename: a.file_name, content: a.decoded_body,
                        mime_type: Drafts::AttachmentAdder.content_type(a.content_type))
        end
      end

      mail.in_reply_to = draft.reply_to_message.message_id.to_s.gsub(/[<>]/, "")
      mail.references  = build_references(draft.reply_to_message)

      Result.new(encoded: mail.encoded, message_id: msg_id,
                 subject: draft.subject, recipient: recipients.all.join(", "))
    end

    def self.build_references(parent)
      chain = []
      seen  = Set.new
      cur   = parent
      while cur && seen.add?(cur.id)
        if cur.message_id.present?
          chain.unshift(cur.message_id.to_s.gsub(/[<>]/, ""))
        end
        cur = cur.reply_to
      end
      chain
    end
  end
end
