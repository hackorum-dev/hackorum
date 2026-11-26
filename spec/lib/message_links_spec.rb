require "rails_helper"

RSpec.describe MessageLinks do
  it "extracts message ids from archive links" do
    body = "see https://postgr.es/m/CAx1%40mail.gmail.com and\n" \
           "https://www.postgresql.org/message-id/flat/abc@ex.org.\n" \
           "> https://postgr.es/m/quoted@ex.org\n" \
           "again (https://postgr.es/m/CAx1@mail.gmail.com)"
    expect(MessageLinks.message_ids(body)).to eq([ "CAx1@mail.gmail.com", "abc@ex.org" ])
  end

  it "decodes non-ascii percent sequences as utf-8" do
    ids = MessageLinks.message_ids("https://postgr.es/m/a%C3%A9b@x.org")
    expect(ids).to eq([ "a\u00e9b@x.org" ])
    expect(ids.first.encoding).to eq(Encoding::UTF_8)
  end

  it "handles literal and encoded non-ascii mixed, and drops invalid bytes" do
    body = "https://postgr.es/m/\u00e9%C3%A9@x.org https://postgr.es/m/bad%FF@x.org"
    expect(MessageLinks.message_ids(body)).to eq([ "\u00e9\u00e9@x.org" ])
  end

  it "strips a trailing anchor and slash" do
    body = "https://www.postgresql.org/message-id/flat/abc@ex.org#def@ex.org " \
           "https://www.postgresql.org/message-id/xyz@ex.org/ https://postgr.es/m/q%23r@ex.org"
    expect(MessageLinks.message_ids(body)).to eq([ "abc@ex.org", "xyz@ex.org", "q#r@ex.org" ])
  end

  it "drops ids with malformed percent sequences" do
    body = "https://postgr.es/m/abc%zz@x.org https://postgr.es/m/abc%. https://postgr.es/m/abc%@x.org"
    expect(MessageLinks.message_ids(body)).to eq([])
  end

  describe ".commit_tokens" do
    it "extracts hash-like tokens" do
      expect(MessageLinks.commit_tokens("Oversight in commit 1a2b3c4d5e.")).to eq([ "1a2b3c4d5e" ])
    end

    it "ignores noise, short tokens and quoted lines, and dedups" do
      body = "date 20240115 lsn 0/1A2B3C4D short abc1234 ptr 0x7ffd12345678\n" \
             "> quoted 1111aaaa2222\n" \
             "see 1a2b3c4d5e and again 1a2b3c4d5e"
      expect(MessageLinks.commit_tokens(body)).to eq([ "1a2b3c4d5e" ])
    end
  end
end
