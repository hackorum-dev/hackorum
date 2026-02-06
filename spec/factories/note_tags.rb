FactoryBot.define do
  factory :note_tag do
    association :note
    tag { "test-tag" }
  end
end
