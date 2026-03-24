FactoryBot.define do
  factory :mailing_list do
    sequence(:identifier) { |n| "pgsql-list-#{n}" }
    sequence(:display_name) { |n| "list-#{n}" }
    sequence(:email) { |n| "pgsql-list-#{n}@lists.postgresql.org" }
  end
end
