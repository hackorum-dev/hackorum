class PatchFile < ApplicationRecord
  belongs_to :attachment

  validates :filename, presence: true
  validates :filename, uniqueness: { scope: :attachment_id }
  validates :status, inclusion: { in: %w[added modified deleted renamed] }

  scope :in_directory, ->(dir) { where("filename LIKE ?", "#{dir}/%") }
  scope :contrib_files, -> { in_directory("contrib") }
  scope :backend_files, -> { in_directory("src/backend") }
end
