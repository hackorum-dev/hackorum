FactoryBot.define do
  factory :patchset_pair do
    topic
    later_message { association(:message, topic: topic) }
    earlier_message { association(:message, topic: topic) }
    metrics { { "file_jaccard" => 1.0 } }
  end
end
