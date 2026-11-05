FactoryBot.define do
  factory :team_feature do
    team
    feature { "email_sending" }
  end
end
