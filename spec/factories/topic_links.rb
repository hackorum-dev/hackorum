FactoryBot.define do
  factory :topic_link do
    topic
    other_topic factory: :topic
    kind { "commit" }
    direction { "both" }
    ref factory: :commit
  end
end
