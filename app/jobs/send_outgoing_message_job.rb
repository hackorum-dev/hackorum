class SendOutgoingMessageJob < ApplicationJob
  queue_as :default

  retry_on Gmail::TransientError, wait: :polynomially_longer, attempts: 5

  def perform(draft_id)
    draft = OutgoingDraft.find_by(id: draft_id)
    return unless draft && draft.sending?

    ActiveSupport::Notifications.instrument("outgoing.send.attempt", draft_id: draft.id)

    OAuth::TokenRefresher.call(draft.identity)
    rfc = Outgoing::MessageBuilder.build(draft)
    Gmail::SendClient.send_raw(draft.identity, rfc.encoded)

    msg = nil
    Message.transaction do
      msg = Message.create!(
        topic:                draft.topic,
        sender:               draft.sender_alias,
        sender_person_id:     draft.sender_alias.person_id,
        reply_to:             draft.reply_to_message,
        reply_to_message_id:  draft.reply_to_message.message_id,
        subject:              rfc.subject,
        body:                 draft.body,
        message_id:           rfc.message_id,
        state:                Message::STATE_PENDING,
        sent_at:              Time.current,
        sent_via_identity_id: draft.identity_id,
        sent_to_address:      rfc.recipient
      )
      draft.update_columns(
        status:             OutgoingDraft::STATUS_SENT,
        sent_message_id:    msg.id,
        sent_at:            Time.current,
        last_send_error:    nil,
        sending_started_at: nil,
        updated_at:         Time.current
      )
    end

    ActiveSupport::Notifications.instrument("outgoing.send.success",
      draft_id: draft_id, message_id: msg.id, recipient: rfc.recipient)
    # Note: a Turbo Stream broadcast lived here but the topic show view has no
    # turbo_stream_from subscription wired up yet, and the message partial relies
    # on request-time locals (number, current_user) that aren't available in the
    # broadcast renderer. Users see the pending message after refreshing the topic.
  rescue Gmail::AuthRevokedError, ActiveRecord::Encryption::Errors::Decryption => e
    ActiveSupport::Notifications.instrument("outgoing.send.failure",
      draft_id: draft&.id, reason: e.class.name, message: e.message)
    msg = e.is_a?(ActiveRecord::Encryption::Errors::Decryption) ?
      "Stored token could not be decrypted (encryption keys may have changed). Please re-authorize sending." :
      "Authorization revoked: #{e.message}"
    fail_draft(draft, msg)
    draft.identity.update_columns(
      send_revoked_at: Time.current,
      refresh_token: nil,
      access_token: nil
    )
  rescue Gmail::PermanentError => e
    ActiveSupport::Notifications.instrument("outgoing.send.failure",
      draft_id: draft&.id, reason: e.class.name, message: e.message)
    fail_draft(draft, e.message)
  end

  private

  def fail_draft(draft, msg)
    draft.update!(
      status: OutgoingDraft::STATUS_IDLE,
      last_send_error: msg,
      sending_started_at: nil
    )
  end
end
