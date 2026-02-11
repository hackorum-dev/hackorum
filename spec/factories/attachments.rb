FactoryBot.define do
  factory :attachment do
    message
    sequence(:file_name) { |n| "patch#{n}.diff" }
    content_type { "text/plain" }
    body { Base64.encode64("Sample patch content\n+added line\n-removed line") }
    created_at { 1.week.ago }
    updated_at { 1.week.ago }

    trait :image do
      file_name { "screenshot.png" }
      content_type { "image/png" }
      body { Base64.encode64("fake image data") }
    end

    trait :text_file do
      file_name { "config.txt" }
      content_type { "text/plain" }
      body { Base64.encode64("configuration file content") }
    end

    trait :patch_file do
      file_name { "feature.patch" }
      content_type { "text/plain" }
      body { Base64.encode64("diff --git a/src/backend/test.c b/src/backend/test.c\nindex 123..456\n--- a/src/backend/test.c\n+++ b/src/backend/test.c\n@@ -1,3 +1,4 @@\n code\n+new line\n more code") }
    end

    trait :content_based_patch do
      file_name { "changes.txt" }
      content_type { "text/plain" }
      body { Base64.encode64("diff --git a/src/backend/test.c b/src/backend/test.c\nindex 123..456\n--- a/src/backend/test.c\n+++ b/src/backend/test.c\n@@ -1,3 +1,4 @@\n code\n+new line\n more code") }
    end
  end
end
