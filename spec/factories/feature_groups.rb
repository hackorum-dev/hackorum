FactoryBot.define do
  factory :feature_group do
    sequence(:name) { |n| "Feature group #{n}" }
    source { "seed" }
  end
end
