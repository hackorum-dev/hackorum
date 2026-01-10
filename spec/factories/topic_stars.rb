FactoryBot.define do
  factory :topic_star do
    association :user
    association :topic
  end
end
