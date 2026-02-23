FactoryBot.define do
  factory :commitfest_patch do
    sequence(:external_id)
    sequence(:title) { |n| "Patch Title ##{n}" }

    trait :with_topic do
      transient { topic { create(:topic) } }
      after(:create) do |cp, ctx|
        create(:commitfest_patch_topic, commitfest_patch: cp, topic: ctx.topic)
      end
    end

    trait :with_commitfest do
      transient { commitfest { create(:commitfest) } }
      after(:create) do |cp, ctx|
        create(:commitfest_patch_commitfest, commitfest_patch: cp, commitfest: ctx.commitfest)
      end
    end

    trait :with_tag do
      transient { commitfest_tag { create(:commitfest_tag) } }
      after(:create) do |cp, ctx|
        create(:commitfest_patch_tag, commitfest_patch: cp, commitfest_tag: ctx.commitfest_tag)
      end
    end
  end
end
