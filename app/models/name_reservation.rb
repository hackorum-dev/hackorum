# frozen_string_literal: true

class NameReservation < ApplicationRecord
  RESERVED_NAMES = %w[global].freeze

  validates :name, presence: true, uniqueness: true
  validates :owner_type, presence: true
  validates :owner_id, presence: true

  def self.reserve!(name:, owner:)
    normalized = normalize(name)
    raise ArgumentError, "Name required" if normalized.blank?
    raise ArgumentError, "Owner must be persisted" unless owner && owner.id
    if reserved?(normalized)
      record = new(name: normalized)
      record.errors.add(:name, "is reserved")
      raise ActiveRecord::RecordInvalid.new(record)
    end

    transaction do
      existing = find_by(name: normalized)
      if existing && (existing.owner_type != owner.class.name || existing.owner_id != owner.id)
        raise ActiveRecord::RecordInvalid.new(existing), "Name already taken"
      end
      reservation = existing || new(name: normalized, owner_type: owner.class.name, owner_id: owner.id)
      reservation.save!
      reservation
    end
  end

  def self.release_for(owner)
    where(owner_type: owner.class.name, owner_id: owner.id).delete_all
  end

  def self.reserved?(name)
    RESERVED_NAMES.include?(normalize(name))
  end

  def self.normalize(str)
    str.to_s.strip.downcase
  end
end
