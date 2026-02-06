FactoryBot.define do
  factory :note_mention do
    association :note
    association :mentionable, factory: :user
  end
end
