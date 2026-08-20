class SavedSearchPreference < ApplicationRecord
  belongs_to :saved_search
  belongs_to :user

  validates :saved_search_id, uniqueness: { scope: :user_id }

  before_save :clear_other_defaults, if: -> { default? && will_save_change_to_default? }

  private

  def clear_other_defaults
    self.class.where(user_id: user_id, default: true).where.not(id: id).update_all(default: false)
  end
end
