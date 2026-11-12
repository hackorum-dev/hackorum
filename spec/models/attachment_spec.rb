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

  describe "#patch_submission_candidate?" do
    def without_body(name, content_type: "text/plain", body: "x")
      row = create(:attachment, file_name: name, content_type: content_type, body: Base64.encode64(body))
      Attachment.metadata.find(row.id)
    end

    it "does not need the body" do
      diff = "diff --git a/a b/a\n@@ -1 +1 @@\n"
      expect(without_body("0001-x.patch").patch_submission_candidate?).to be(true)
      expect(without_body("patch").patch_submission_candidate?).to be(true)
      expect(without_body("fix.patch.3").patch_submission_candidate?).to be(true)
      expect(without_body("fix.txt", content_type: "text/x-patch").patch_submission_candidate?).to be(true)
      expect(without_body("notes.txt", body: diff).patch_submission_candidate?).to be(false)
      expect(without_body("fix.patch.nocfbot", body: diff).patch_submission_candidate?).to be(false)
      expect(without_body("nocfbot-0001-fix.txt", body: diff).patch_submission_candidate?).to be(false)
      expect(without_body("").patch_submission_candidate?).to be(false)
    end

    it "leaves the lineage test of a nocfbot file on the body" do
      expect { without_body("nocfbot-0001-fix.txt").lineage_patch_candidate? }
        .to raise_error(ActiveModel::MissingAttributeError)
    end
  end

  describe "byte_size" do
    it "is the decoded size, kept in step with the body" do
      binary = (0..255).map(&:chr).join.b * 3
      a = create(:attachment, body: Base64.encode64(binary))
      expect(a.body).to include("\n")
      expect(a.reload.byte_size).to eq(768)

      a.update!(body: Base64.strict_encode64("abcde"))
      expect(a.reload.byte_size).to eq(5)

      a.update!(file_name: "other.txt")
      expect(a.reload.byte_size).to eq(5)

      a.update!(body: nil)
      expect(a.reload.byte_size).to eq(0)
    end

    it "is 0 for a missing or empty body" do
      expect(create(:attachment, body: nil).reload.byte_size).to eq(0)
      expect(create(:attachment, body: "").reload.byte_size).to eq(0)
    end

    it "ignores a value given next to a body" do
      expect(create(:attachment, body: Base64.encode64("abc"), byte_size: 99).reload.byte_size).to eq(3)
    end

    it "takes a body that is not Base64" do
      a = create(:attachment, body: "!!! not base64 ???")
      expect(a.reload.byte_size).to eq(Base64.decode64("!!! not base64 ???").bytesize)

      get_metadata = Attachment.metadata.find(a.id)
      expect(get_metadata.byte_size).to eq(a.byte_size)
      expect(get_metadata.has_attribute?(:body)).to be(false)
    end

    it "is not touched when a row loaded without its body is saved" do
      a = create(:attachment, body: Base64.encode64("abcdef"))

      Attachment.metadata.find(a.id).update!(file_name: "renamed.txt")

      expect(a.reload).to have_attributes(byte_size: 6, file_name: "renamed.txt")
    end
  end
end
