# frozen_string_literal: true

class CommitfestPatchMessage < ApplicationRecord
  belongs_to :commitfest_patch
  belongs_to :message, optional: true, foreign_key: :message_record_id

  validates :message_id, presence: true
end
