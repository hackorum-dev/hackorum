FactoryBot.define do
  factory :topic_merge do
    association :source_topic, factory: :topic
    association :target_topic, factory: :topic
    association :merged_by, factory: :user
    merge_reason { "Split thread that should be one conversation" }
  end
end
