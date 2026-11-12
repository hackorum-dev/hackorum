require "rails_helper"

RSpec.describe Drafts::AttachmentAdder do
  let(:draft) { create(:outgoing_draft, updated_at: 1.hour.ago) }
  let(:cap) { OutgoingDraft::MAX_ATTACHMENT_BYTES }

  def file(name = "fix.patch", bytes = "diff\n", content_type = "text/x-diff")
    { name: name, content_type: content_type, bytes: bytes }
  end

  def call(*files, **options)
    described_class.call(draft: draft, files: files, **options)
  end

  def unchanged
    before = draft.reload.attributes
    yield
    expect(draft.reload.attributes).to eq(before)
  end

  it "stores the files as the mail builder reads them" do
    bytes = (0..255).map(&:chr).join.b * 3

    result = call(file("a.patch", "diff\n"), file("b.bin", bytes, nil))

    expect(result).to be_added
    expect(result.total).to eq(5 + bytes.bytesize)
    first, second = draft.draft_attachments.order(:id).to_a
    expect(first).to have_attributes(file_name: "a.patch", content_type: "text/x-diff", byte_size: 5, body: Base64.encode64("diff\n"))
    expect(second).to have_attributes(file_name: "b.bin", content_type: "application/octet-stream", byte_size: bytes.bytesize)
    expect(second.decoded_body).to eq(bytes)
  end

  it "takes the name of the file without its path and without characters a header cannot have" do
    names = {
      "dir/sub/fix.patch" => "fix.patch",
      "../../etc/passwd" => "passwd",
      "a\"b\r\nc.txt" => "a_b__c.txt",
      "a\\b.txt" => "a_b.txt",
      "bad\xFF.txt" => "bad_.txt",
      "" => "attachment",
      nil => "attachment"
    }

    names.each do |raw, stored|
      expect(described_class.file_name(raw)).to eq(stored), raw.inspect
    end
    call(file("dir/fix.patch"))
    expect(draft.draft_attachments.sole.file_name).to eq("fix.patch")
  end

  it "strips characters that hide or reorder a name, and names what is left of nothing" do
    names = {
      "a\u200Bb\u200D.txt" => "ab.txt",
      "\uFEFFfix.patch" => "fix.patch",
      "invoice\u202Etxt.exe" => "invoicetxt.exe",
      "a\u2028b\u2029c.txt" => "abc.txt",
      "a\u0085b\x7Fc.txt" => "a_b_c.txt",
      ".." => "attachment",
      "." => "attachment",
      "..." => "attachment",
      "/" => "attachment",
      "dir/.." => "attachment",
      "///" => "attachment",
      "  " => "attachment",
      " . . " => "attachment",
      "\u200B\u202E" => "attachment",
      "\u202E.." => "attachment",
      "\u00A0\u3000" => "attachment",
      "  spaced.txt " => "spaced.txt",
      ".gitignore" => ".gitignore",
      "caf\u00E9 \u65E5\u672C.txt" => "caf\u00E9 \u65E5\u672C.txt",
      "bin\xFF.txt".b => "bin_.txt"
    }

    names.each do |raw, stored|
      expect(described_class.file_name(raw)).to eq(stored), raw.inspect
    end
  end

  describe ".content_type" do
    def plain(raw) = described_class.content_type(raw)

    it "keeps a type and subtype, in lower case" do
      expect(plain("text/x-diff")).to eq("text/x-diff")
      expect(plain(" Text/X-Diff ")).to eq("text/x-diff")
      expect(plain("application/vnd.ms-excel")).to eq("application/vnd.ms-excel")
      expect(plain("image/svg+xml")).to eq("image/svg+xml")
    end

    it "is the default without a usable type" do
      [ nil, "", "text", "text/", "/plain", "text/plain/extra", "text/pl ain", "te xt/plain", "text/plain\r\nX-Evil: 1",
        "text/\"plain\"", "text/plain, text/html", "t\u00E9xt/plain", "\xFF/x", "a" * 200 + "/b" ].each do |raw|
        expect(plain(raw)).to eq("application/octet-stream"), raw.inspect
      end
    end

    it "is the default for types that hold parts or messages" do
      [ "multipart/mixed; boundary=abc", "Multipart/Alternative", "multipart/related;boundary=x", "message/rfc822",
        "MESSAGE/partial; id=1", "message/external-body" ].each do |raw|
        expect(plain(raw)).to eq("application/octet-stream"), raw.inspect
      end
    end

    it "drops every parameter but one known charset" do
      expect(plain('text/plain; name="evil.exe"')).to eq("text/plain")
      expect(plain("text/plain; boundary=abc; format=flowed")).to eq("text/plain")
      expect(plain("text/plain; charset=UTF-8")).to eq("text/plain; charset=utf-8")
      expect(plain('text/plain;CHARSET="ISO-8859-1"; name=x')).to eq("text/plain; charset=iso-8859-1")
      expect(plain("text/x-diff; charset=windows-1252")).to eq("text/x-diff; charset=windows-1252")
      expect(plain("text/plain; charset=utf-7")).to eq("text/plain")
      expect(plain("text/plain; charset=utf-8\r\nX-Evil: 1")).to eq("text/plain")
      expect(plain("text/plain; charset*=utf-8''x")).to eq("text/plain")
    end

    it "emits a repeated charset once, and none when the values differ" do
      expect(plain("text/plain; charset=utf-8; charset=UTF-8")).to eq("text/plain; charset=utf-8")
      expect(plain("text/plain; charset=utf-8; charset=utf-7")).to eq("text/plain")
      expect(plain("text/plain; charset=utf-8; charset=iso-8859-1")).to eq("text/plain")
    end
  end

  it "stores the plain content type" do
    call(file("a", "x", "multipart/mixed; boundary=abc"), file("b", "x", "message/rfc822"),
         file("c", "x", 'Text/Plain; name="evil.exe"; charset=us-ascii'), file("d", "x", ""))

    expect(draft.draft_attachments.order(:id).pluck(:content_type))
      .to eq([ "application/octet-stream", "application/octet-stream", "text/plain; charset=us-ascii", "application/octet-stream" ])
  end

  it "changes updated_at of the draft, and names the token when there is one" do
    token = ApiToken.issue!(user: draft.user, name: "agent").first
    draft.update_columns(last_edited_via_token_id: token.id)
    was = draft.updated_at

    call(file)
    expect(draft.reload.updated_at).to be > was
    expect(draft.last_edited_via_token).to eq(token)

    other = ApiToken.issue!(user: draft.user, name: "other").first
    draft.update_columns(updated_at: was)
    call(file, token: other)
    expect(draft.reload.updated_at).to be > was
    expect(draft.last_edited_via_token).to eq(other)
  end

  it "takes a total of exactly the cap and not one byte more" do
    create(:draft_attachment, outgoing_draft: draft, content: "x", byte_size: cap - 10)

    expect(call(file("a", "x" * 4), file("b", "x" * 6))).to be_added
    expect(draft.draft_attachments.count).to eq(3)

    unchanged do
      result = call(file("c", "x"))

      expect(result).to be_too_large
      expect(result.total).to eq(cap + 1)
    end
    expect(draft.draft_attachments.count).to eq(3)
  end

  it "stores none of the files when together they are over the cap" do
    unchanged do
      expect(call(file("a", "x" * (cap - 1)), file("b", "xx"))).to be_too_large
    end
    expect(DraftAttachment.count).to eq(0)
  end

  it "stores nothing on a draft that is being sent or was sent" do
    draft.update_columns(status: "sending")
    unchanged { expect(call(file)).to be_sending }

    draft.update_columns(status: "sent")
    unchanged { expect(call(file)).to be_sent }

    expect(DraftAttachment.count).to eq(0)
  end

  it "sees the state the draft has under the lock" do
    stale = OutgoingDraft.find(draft.id)
    draft.update_columns(status: "sending")

    expect(described_class.call(draft: stale, files: [ file ])).to be_sending
    expect(DraftAttachment.count).to eq(0)
  end

  it "leaves the draft alone without files" do
    unchanged { expect(call).to be_added }
  end
end
