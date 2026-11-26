FactoryBot.define do
  factory :feature_group_version do
    feature_group
    sequence(:major) { |n| 20 + n }
    status { "in-development" }
    source { "computed" }
  end
end
