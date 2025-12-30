# frozen_string_literal: true

class CommitfestPatchCommitfest < ApplicationRecord
  belongs_to :commitfest
  belongs_to :commitfest_patch

  validates :status, presence: true
end
