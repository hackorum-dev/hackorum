class SavedSearchPreference < ApplicationRecord
  belongs_to :saved_search
  belongs_to :user

  validates :saved_search_id, uniqueness: { scope: :user_id }
end
