class ApiToken < ApplicationRecord
  PREFIX = "hko_"
  MAX_PER_USER = 20
  LAST_USED_RESOLUTION = 1.minute

  belongs_to :user

  validates :name, presence: true, length: { maximum: 100 }, format: { without: /[[:cntrl:]]/ }
  validates :token_digest, presence: true

  scope :active, -> { where(revoked_at: nil).where("api_tokens.expires_at IS NULL OR api_tokens.expires_at > ?", Time.current) }

  def self.issue!(user:, name:, expires_at: nil)
    raw = PREFIX + SecureRandom.urlsafe_base64(32)
    [ create!(user: user, name: name, expires_at: expires_at, token_digest: digest(raw)), raw ]
  end

  def self.authenticate(raw)
    raw = raw.to_s
    return nil unless raw.start_with?(PREFIX)
    active.eager_load(:user).merge(User.active).find_by(token_digest: digest(raw))
  end

  def self.digest(raw)
    OpenSSL::Digest::SHA256.hexdigest(raw)
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  def touch_last_used!
    now = Time.current
    return if last_used_at && last_used_at > now - LAST_USED_RESOLUTION
    update_columns(last_used_at: now)
  end
end
