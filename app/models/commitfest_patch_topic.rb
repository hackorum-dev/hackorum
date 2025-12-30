# frozen_string_literal: true

class CommitfestPatchTopic < ApplicationRecord
  belongs_to :commitfest_patch
  belongs_to :topic
end
