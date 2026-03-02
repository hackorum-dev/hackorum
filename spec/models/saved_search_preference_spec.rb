require "rails_helper"

RSpec.describe SavedSearchPreference, type: :model do
  it "enforces uniqueness of saved_search per user" do
    user = create(:user)
    search = create(:saved_search)
    create(:saved_search_preference, saved_search: search, user: user)

    dup = build(:saved_search_preference, saved_search: search, user: user)
    expect(dup).not_to be_valid
  end
end
