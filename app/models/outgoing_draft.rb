class OutgoingDraft < ApplicationRecord
  STATUS_IDLE    = "idle"
  STATUS_SENDING = "sending"
  STATUS_SENT    = "sent"

  STATUSES = [ STATUS_IDLE, STATUS_SENDING, STATUS_SENT ].freeze
  MAX_ATTACHMENT_BYTES = 2.megabytes

  belongs_to :user
  belongs_to :topic
  belongs_to :reply_to_message, class_name: "Message"
  belongs_to :sender_alias, class_name: "Alias"
  belongs_to :identity
  belongs_to :sent_message, class_name: "Message", optional: true
  belongs_to :created_via_token, class_name: "ApiToken", optional: true
  belongs_to :last_edited_via_token, class_name: "ApiToken", optional: true
  has_many :draft_attachments, dependent: :delete_all

  validates :subject, presence: true
  validates :status, inclusion: { in: STATUSES }
  # `if:` gates whether the validation runs on this record; `conditions:` scopes the existence query against other rows. Both are needed to mirror the DB partial unique index.
  validates :user_id,
            uniqueness: {
              scope: :reply_to_message_id,
              conditions: -> { where(status: [ STATUS_IDLE, STATUS_SENDING ]) }
            },
            if: :active?

  scope :idle,    -> { where(status: STATUS_IDLE) }
  scope :sending, -> { where(status: STATUS_SENDING) }
  scope :sent,    -> { where(status: STATUS_SENT) }
  scope :stale_sending, ->(threshold = 20.minutes.ago) {
    sending.where("sending_started_at < ?", threshold)
  }

  def idle?    = status == STATUS_IDLE
  def sending? = status == STATUS_SENDING
  def sent?    = status == STATUS_SENT
  def active?  = idle? || sending?

  def attachment_bytes = draft_attachments.sum(:byte_size)

  # changes with every edit of the text or the files
  def version = updated_at.utc.iso8601(6)

  def failed? = idle? && last_send_error.present?

  # Use status_was, not sent?: the sending->sent transition save needs readonly? to
  # return false at the moment of write, and factory inserts of status: 'sent' must succeed.
  def readonly? = persisted? && status_was == STATUS_SENT
end
