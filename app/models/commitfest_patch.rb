# frozen_string_literal: true

class CommitfestPatch < ApplicationRecord
  has_many :commitfest_patch_commitfests, dependent: :destroy
  has_many :commitfests, through: :commitfest_patch_commitfests
  has_many :commitfest_patch_tags, dependent: :destroy
  has_many :commitfest_tags, through: :commitfest_patch_tags
  has_many :commitfest_patch_messages, dependent: :destroy
  has_many :commitfest_patch_topics, dependent: :destroy
  has_many :topics, through: :commitfest_patch_topics

  validates :external_id, :title, presence: true
end
