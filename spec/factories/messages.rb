FactoryBot.define do
  factory :message do
    transient do
      sender_alias { nil }
    end

    topic
    sender { sender_alias || association(:alias, strategy: :create) }
    sender_person_id { sender.person_id }
    reply_to { nil }
    sequence(:subject) { |n| "Re: PostgreSQL Feature Discussion #{n}" }
    sequence(:message_id) { |n| "<message#{n}@postgresql.org>" }
    sequence(:body) { |n| "This is message #{n} discussing PostgreSQL features and development." }
    import_log { nil }
    created_at { 1.week.ago }
    updated_at { 1.week.ago }

    trait :root_message do
      reply_to { nil }
      subject { topic.title }
    end

    trait :reply do
      reply_to { association(:message, topic: topic) }
    end

    trait :recent do
      created_at { 1.day.ago }
      updated_at { 1.day.ago }
    end

    trait :with_import_log do
      import_log { "Reference msg id not found: <missing@example.com>" }
    end

    trait :with_attachments do
      after(:create) do |message|
        create_list(:attachment, 2, message: message)
      end
    end
  end
end
