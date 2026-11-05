class DraftAttachment < ApplicationRecord
  belongs_to :outgoing_draft

  validates :file_name, :body, :byte_size, presence: true

  scope :listing, -> { select(:id, :outgoing_draft_id, :file_name, :byte_size).order(:id) }

  def decoded_body
    Base64.decode64(body) if body.present?
  end
end
