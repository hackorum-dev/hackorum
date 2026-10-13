class GlobalTag < ApplicationRecord
  belongs_to :created_by, class_name: "User"

  attr_readonly :name

  before_validation :normalize_name, on: :create
  before_destroy :ensure_unused

  validates :name, presence: true, format: { with: NoteTag::TAG_FORMAT }, uniqueness: true
  validates :description, length: { maximum: 200 }

  scope :active, -> { where(retired_at: nil) }
  scope :retired, -> { where.not(retired_at: nil) }

  def self.global_note_tags
    NoteTag.joins(:note).merge(Note.global_visible)
  end

  def self.usage_counts
    global_note_tags.group(:tag).distinct.count("notes.topic_id")
  end

  def retired?
    retired_at.present?
  end

  def retire!
    update!(retired_at: Time.current)
  end

  def unretire!
    update!(retired_at: nil)
  end

  def in_use?
    self.class.global_note_tags.where(tag: name).exists?
  end

  private

  def normalize_name
    self.name = name.to_s.strip.downcase
  end

  def ensure_unused
    return unless in_use?

    errors.add(:base, "Tag is in use, retire it instead")
    throw :abort
  end
end
