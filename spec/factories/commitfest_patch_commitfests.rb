FactoryBot.define do
  factory :commitfest_patch_commitfest do
    commitfest
    commitfest_patch

    status { "Open" }
  end
end
