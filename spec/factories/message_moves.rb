FactoryBot.define do
  factory :message_move do
    association :topic_merge
    association :message
  end
end
