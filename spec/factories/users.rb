FactoryBot.define do
  factory :user do
    person
    created_at { 1.month.ago }
    updated_at { 1.month.ago }
    verified_at { 1.month.ago }
  end
end
