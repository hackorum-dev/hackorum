# frozen_string_literal: true

class Commitfest < ApplicationRecord
  has_many :commitfest_patch_commitfests, dependent: :destroy
  has_many :commitfest_patches, through: :commitfest_patch_commitfests

  validates :external_id, :name, :status, :start_date, :end_date, presence: true
end
