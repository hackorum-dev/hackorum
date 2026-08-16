FactoryBot.define do
  factory :person_merge do
    association :performed_by, factory: :user
    source_person_id { create(:person).id }
    target_person_id { create(:person).id }
    source_name { "Old Name" }
    target_name { "Kept Name" }
    source_emails { [ "old@example.com" ] }
    aliases_moved { 1 }
    topics_moved { 0 }
    messages_moved { 0 }
  end
end
