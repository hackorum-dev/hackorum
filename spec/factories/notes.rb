FactoryBot.define do
  factory :note do
    association :topic
    association :author, factory: :user
    body { "This is a test note" }

    trait :with_message do
      message { association(:message, topic: topic) }
    end
  end
end
