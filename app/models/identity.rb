require "net/http"

class Identity < ApplicationRecord
  belongs_to :user

  encrypts :refresh_token
  encrypts :access_token

  validates :provider, presence: true
  validates :uid, presence: true
  validates :uid, uniqueness: { scope: :provider }

  scope :send_authorized, -> {
    where.not(refresh_token: nil).where(send_revoked_at: nil)
  }

  def send_authorized?
    !refresh_token.nil? && send_revoked_at.nil?
  end

  # best effort, the local grant is dropped either way
  def revoke_remotely
    return if refresh_token.blank?
    Net::HTTP.post_form(URI("https://oauth2.googleapis.com/revoke"), token: refresh_token)
  rescue StandardError => e
    Rails.logger.warn("Google revoke failed: #{e.class}: #{e.message}")
  end
end
