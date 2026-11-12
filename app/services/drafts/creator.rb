module Drafts
  # Makes the reply draft of a user for a message, or finds the active one.
  class Creator
    class NoSendIdentity < StandardError; end
    class NoSenderAlias < StandardError; end
    class LimitReached < StandardError; end
    class BodyTooLarge < StandardError; end

    Result = Struct.new(:draft, :created) do
      def created? = created
    end

    def self.call(...)
      new(...).call
    end

    # a token brings the limits of Drafts::TokenLimits, max_body_bytes is for the stored text
    def initialize(user:, reply_to_message:, subject: nil, body: nil, quote: nil, token: nil, max_body_bytes: nil)
      @user = user
      @parent = reply_to_message
      @subject = subject
      @body = body
      @quote = quote
      @token = token
      @max_body_bytes = max_body_bytes
    end

    def call
      identity = @user.identities.send_authorized.first
      raise NoSendIdentity if identity.nil?

      sender = @user.sender_alias_for(identity.email)
      raise NoSenderAlias if sender.nil?

      existing = active_draft
      return Result.new(existing, false) if existing
      raise LimitReached if @token && TokenLimits.drafts_reached?(@user)

      text = "#{quoted}#{@body}"
      raise BodyTooLarge if @max_body_bytes && text.bytesize > @max_body_bytes

      create(identity, sender, text)
    end

    private

    def active_draft
      @user.outgoing_drafts.where.not(status: OutgoingDraft::STATUS_SENT).find_by(reply_to_message_id: @parent.id)
    end

    # in a savepoint: a unique violation must not abort the caller's transaction
    def create(identity, sender, text)
      draft = OutgoingDraft.transaction(requires_new: true) do
        @user.outgoing_drafts.create!(
          topic: @parent.topic,
          reply_to_message: @parent,
          identity: identity,
          sender_alias: sender,
          subject: @subject || default_subject,
          body: text,
          created_via_token: @token
        )
      end
      Result.new(draft, true)
    rescue ActiveRecord::RecordNotUnique
      Result.new(active_draft || raise, false)
    rescue ActiveRecord::RecordInvalid => e
      raise unless e.record.errors.of_kind?(:user_id, :taken)
      Result.new(active_draft || raise, false)
    end

    def default_subject
      "Re: #{@parent.subject.to_s.sub(/\A(re|aw|fwd):\s*/i, '')}"
    end

    def quoted
      return "" if @quote.blank?

      display = @parent.sender_display_alias
      header = "On #{@parent.created_at.strftime('%a, %d %b %Y')}, #{display.name} <#{display.email}> wrote:"
      lines = @quote.strip.each_line.map { |line| "> #{line.chomp}" }.join("\n")
      "#{header}\n#{lines}\n\n"
    end
  end
end
