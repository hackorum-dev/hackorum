FactoryBot.define do
  factory :classification_run do
    topic
    status { "done" }
    phase { "new" }
    worker { "test" }
    started_at { 10.minutes.ago }
    finished_at { Time.current }
    message_count { topic.message_count }
  end
end
