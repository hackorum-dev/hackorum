FactoryBot.define do
  factory :feature_group_topic do
    feature_group
    topic
    source { "llm" }
  end
end
