FactoryBot.define do
  factory :patchset_lineage do
    patchset_run
    topic { patchset_run.topic }
    message { association(:message, topic: topic) }
    parent_message { nil }
    step_kind { "new_series" }
    confidence { 0.9 }
    reason { "first version" }
  end
end
