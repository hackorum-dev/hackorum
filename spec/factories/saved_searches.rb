FactoryBot.define do
  factory :saved_search do
    sequence(:name) { |n| "Search #{n}" }
    query { "unread:true" }
    scope { "global" }
  end
end
