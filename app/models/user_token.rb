class UserToken < ApplicationRecord
  PURPOSES = %w[register add_alias reset_password].freeze

  belongs_to :user, optional: true

  validates :purpose, inclusion: { in: PURPOSES }
  validates :token_digest, presence: true
  validates :expires_at, presence: true

  scope :unconsumed, -> { where(consumed_at: nil) }

  after_destroy :release_name_reservation

  def consumed?
    consumed_at.present?
  end

  def expired?
    Time.current >= expires_at
  end

  def consume!
    update!(consumed_at: Time.current)
  end

  def self.issue!(purpose:, email: nil, user: nil, ttl: 1.hour, metadata: nil)
    raw = SecureRandom.urlsafe_base64(32)
    digest = digest(raw)
    record = create!(
      user: user,
      email: email,
      purpose: purpose,
      token_digest: digest,
      expires_at: Time.current + ttl,
      metadata: metadata
    )
    [ record, raw ]
  end

  def self.consume!(raw, purpose: nil)
    record = find_by(token_digest: digest(raw))
    return nil unless record
    return nil if purpose && record.purpose != purpose
    return nil if record.expired? || record.consumed?
    record.consume!
    record
  end

  def self.digest(raw)
    OpenSSL::Digest::SHA256.hexdigest(raw)
  end

  def self.cleanup_expired!(older_than: 1.day)
    where("expires_at < ? OR consumed_at < ?", older_than.ago, older_than.ago).destroy_all
  end

  private

  def release_name_reservation
    NameReservation.release_for(self)
  end
end
