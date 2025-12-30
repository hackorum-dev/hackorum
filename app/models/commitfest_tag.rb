# frozen_string_literal: true

class CommitfestTag < ApplicationRecord
  has_many :commitfest_patch_tags, dependent: :destroy
  has_many :commitfest_patches, through: :commitfest_patch_tags

  validates :name, presence: true
end
