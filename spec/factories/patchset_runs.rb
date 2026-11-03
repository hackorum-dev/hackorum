FactoryBot.define do
  factory :patchset_run do
    topic
    status { "done" }
    model { "gpt-6-test" }
    started_at { 1.hour.ago }
    finished_at { 50.minutes.ago }
    duration_s { 600.0 }
    story { "Patchsets 1-3 became commit A." }
  end
end
