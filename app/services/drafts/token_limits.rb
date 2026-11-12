module Drafts
  # What one user may hold in drafts that API tokens make and fill.
  # Checked without a lock on the user: parallel requests can pass it by one.
  module TokenLimits
    ACTIVE_DRAFTS = 50
    ATTACHMENT_BYTES = 20.megabytes

    def self.active(user)
      user.outgoing_drafts.where.not(status: OutgoingDraft::STATUS_SENT)
    end

    def self.drafts_reached?(user)
      active(user).count >= ACTIVE_DRAFTS
    end

    def self.attachment_bytes(user)
      DraftAttachment.where(outgoing_draft_id: active(user).select(:id)).sum(:byte_size)
    end
  end
end
