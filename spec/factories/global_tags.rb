FactoryBot.define do
  factory :global_tag do
    sequence(:name) { |n| "global-tag-#{n}" }
    association :created_by, factory: :user
  end
end
