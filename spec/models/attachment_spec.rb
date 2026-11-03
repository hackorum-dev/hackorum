require "rails_helper"

RSpec.describe Attachment do
  def predicates(name, body: "x", content_type: "text/plain")
    a = build(:attachment, file_name: name, content_type: content_type, body: Base64.encode64(body))
    [ a.patch_submission_candidate?, a.lineage_patch_candidate?, a.nocfbot? ]
  end

  it "classifies names" do
    expect(predicates("fix.patch.nocfbot")).to eq([ false, true, true ])
    expect(predicates("x.patch.no_cfbot")).to eq([ false, true, true ])
    expect(predicates("0001-x.patch")).to eq([ true, true, false ])
    expect(predicates("foo.patch_")).to eq([ false, false, false ])
  end

  it "accepts nocfbot txt files only when the body is a diff" do
    diff = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-a\n+b\n"
    expect(predicates("nocfbot-0001-fix.txt", body: diff)).to eq([ false, true, true ])
    expect(predicates("nocfbot-0001-fix.txt", body: "just prose")).to eq([ false, false, true ])
  end
end
