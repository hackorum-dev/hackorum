# frozen_string_literal: true

class ImapSyncState < ApplicationRecord
  validates :mailbox_label, presence: true, uniqueness: true

  def self.for_label(label = "INBOX")
    find_or_create_by!(mailbox_label: label) do |s|
      s.last_uid = 0
    end
  end
end
