FactoryBot.define do
  factory :mention do
    transient do
      mention_alias { association(:alias) }
    end

    message
    association :alias, factory: :alias
    person_id { self.alias.person_id }
    created_at { 1.week.ago }
    updated_at { 1.week.ago }

    after(:build) do |mention|
      mention.person_id ||= mention.alias&.person_id
    end
  end
end
