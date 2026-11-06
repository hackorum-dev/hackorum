# Where a person worked and when, from public sources. No row is ever
# committed to the repo; the scripts under script/affiliations fill the table.
class PersonAffiliation < ApplicationRecord
  SOURCES = %w[contributors_page domain manual].freeze

  belongs_to :person

  validates :company, presence: true
  validates :source, inclusion: { in: SOURCES }
  validate :ordered_range

  private

  def ordered_range
    return if since.nil? || self.until.nil? || self.until >= since

    errors.add(:until, "must not precede since")
  end
end
