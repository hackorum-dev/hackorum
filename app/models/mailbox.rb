class Mailbox < ApplicationRecord
  DEFAULT_QUOTA_MB = 5120
  QUOTA_RANGE = (1..102_400)
  MIN_PASSWORD_LENGTH = 12
  MAX_PASSWORD_LENGTH = 128

  belongs_to :user
  has_many :addresses, class_name: "MailboxAddress", dependent: :destroy

  validates :user_id, uniqueness: true
  validates :quota_mb, numericality: { only_integer: true, in: QUOTA_RANGE }
  validate :user_active, on: :create

  after_commit { MailConfigRenderJob.perform_later }

  scope :enabled, -> { where(disabled_at: nil) }

  def self.grant!(user:, login:, quota_mb: DEFAULT_QUOTA_MB)
    transaction do
      mailbox = create!(user: user, quota_mb: quota_mb, password_hash: MailPasswordHash.create(SecureRandom.alphanumeric(32)))
      address = mailbox.addresses.build(local_part: login, login: true)
      unless address.save
        address.errors.each { |e| mailbox.errors.add(:login, e.message) }
        raise ActiveRecord::RecordInvalid, mailbox
      end
      mailbox
    end
  rescue ActiveRecord::RecordNotUnique
    mailbox = new(user: user)
    mailbox.errors.add(:login, "is already taken")
    raise ActiveRecord::RecordInvalid, mailbox
  end

  def login_address
    addresses.find_by(login: true)
  end

  def login_local_part
    login_address&.local_part
  end

  def alias_addresses
    addresses.where(login: false).order(:local_part)
  end

  def add_alias(local_part)
    address = addresses.build(local_part: local_part)
    MailboxAddress.transaction(requires_new: true) { address.save }
    address
  rescue ActiveRecord::RecordNotUnique
    address.errors.add(:local_part, "is already taken")
    address
  end

  def change_password(plain)
    errors.delete(:password)
    error = password_error(plain)
    if error
      errors.add(:password, error)
      return false
    end
    store_password(plain)
    true
  end

  def generate_password!
    plain = SecureRandom.alphanumeric(24)
    store_password(plain)
    plain
  end

  def disabled?
    disabled_at.present?
  end

  def disable!
    update!(disabled_at: Time.current)
  end

  def enable!
    if user.deleted_at.present?
      errors.add(:user, "is deleted")
      return false
    end
    update!(disabled_at: nil)
  end

  private

  def store_password(plain)
    transaction do
      update_column(:password_hash, MailPasswordHash.create(plain))
      touch
    end
  end

  def password_error(plain)
    return "must be a string" unless plain.is_a?(String)
    return "is too short (minimum is #{MIN_PASSWORD_LENGTH} characters)" if plain.length < MIN_PASSWORD_LENGTH
    return "is too long (maximum is #{MAX_PASSWORD_LENGTH} characters)" if plain.length > MAX_PASSWORD_LENGTH
    return "contains invalid characters" if !plain.valid_encoding? || plain.match?(/[[:cntrl:]]/)
    "must differ from your site password" if user.password_digest.present? && user.authenticate(plain)
  end

  def user_active
    return unless user
    errors.add(:user, "must be verified") unless user.verified?
    errors.add(:user, "is deleted") if user.deleted_at.present?
  end
end
