FactoryBot.define do
  factory :draft_attachment do
    outgoing_draft
    sequence(:file_name) { |n| "fix#{n}.patch" }
    content_type { "text/x-diff" }
    transient do
      content { "diff --git a/x b/x\n+line\n" }
    end
    body { Base64.encode64(content) }
    byte_size { content.bytesize }
  end
end
