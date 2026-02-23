FactoryBot.define do
  factory :commitfest do
    sequence(:external_id)
    sequence(:name) { |n| "PG#{n}-Final" }
    status { "Open" }
    start_date { 1.month.ago }
    end_date { 1.month.from_now }
  end
end
