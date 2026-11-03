FactoryBot.define do
  factory :commit_verdict do
    patchset_run
    topic { patchset_run.topic }
    commit
    verdict { "as_is" }
    source_message { nil }
    confidence { 0.9 }
    evidence { "identical hunks" }
  end
end
