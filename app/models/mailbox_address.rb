class MailboxAddress < ApplicationRecord
  FORMAT = /\A[a-z0-9](?:[a-z0-9._-]*[a-z0-9])?\z/

  belongs_to :mailbox

  attr_readonly :local_part, :login

  before_validation(on: :create) { self.local_part = self.class.normalize(local_part) }

  validates :local_part, presence: true, length: { maximum: 64 }, uniqueness: true
  validates :local_part, format: { with: FORMAT }, allow_blank: true
  validate :no_consecutive_dots
  validate :name_available, on: :create
  validate :no_system_account_mixup, on: :create

  after_commit { MailConfigRenderJob.perform_later }
  after_create :reserve_name
  after_destroy { NameReservation.release_for(self) }
  before_destroy :protect_login

  def self.normalize(str)
    str.to_s.strip.downcase
  end

  private

  def no_consecutive_dots
    errors.add(:local_part, :invalid) if local_part.to_s.include?("..")
  end

  def name_available
    return if local_part.blank?
    if NameReservation.reserved?(local_part)
      errors.add(:local_part, "is reserved")
    elsif (existing = NameReservation.find_by(name: local_part)) && !owned_by_user?(existing)
      errors.add(:local_part, "is already taken")
    end
  end

  def no_system_account_mixup
    return unless login? && local_part.present?
    return unless MailConfig::SYSTEM_ACCOUNTS.any? { |system| MailConfig.mixed_up?(local_part, system) }
    errors.add(:local_part, "conflicts with a system mail account")
  end

  def owned_by_user?(reservation)
    reservation.owner_type == "User" && reservation.owner_id == mailbox&.user_id
  end

  def reserve_name
    existing = NameReservation.find_by(name: local_part)
    return if existing && owned_by_user?(existing)
    NameReservation.reserve!(name: local_part, owner: self)
  rescue ActiveRecord::RecordInvalid
    raise ActiveRecord::RecordNotUnique, "name #{local_part} already reserved"
  end

  def protect_login
    throw :abort if login? && !destroyed_by_association
  end
end
