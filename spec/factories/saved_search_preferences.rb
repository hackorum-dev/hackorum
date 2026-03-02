FactoryBot.define do
  factory :saved_search_preference do
    saved_search
    user
    hidden { false }
  end
end
