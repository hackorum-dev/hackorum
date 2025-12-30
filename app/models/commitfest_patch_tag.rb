# frozen_string_literal: true

class CommitfestPatchTag < ApplicationRecord
  belongs_to :commitfest_patch
  belongs_to :commitfest_tag
end
