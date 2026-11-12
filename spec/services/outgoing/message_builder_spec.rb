require 'rails_helper'

RSpec.describe Outgoing::MessageBuilder do
  let(:user)     { create(:user) }
  let(:identity) { create(:identity, user: user, email: 'a@b', refresh_token: 'r') }
  let(:sender)   { create(:alias, user: user, name: 'Alice', email: 'a@b') }
  let(:list)     { create(:mailing_list, post_address: 'list@example.com') }
  let(:topic)    { create(:topic, mailing_lists: [ list ]) }
  let(:parent) {
    create(:message, topic: topic, message_id: '<parent-id@x>',
           mailing_lists: [ list ])
  }

  def recipients(to:, cc: [])
    Outgoing::RecipientResolver::Recipients.new(to: to, cc: cc)
  end

  before do
    allow(Outgoing::RecipientResolver).to receive(:for)
      .with(kind_of(OutgoingDraft))
      .and_return(recipients(to: [ 'test@example.com' ]))
  end

  def build_draft(overrides = {})
    create(:outgoing_draft,
           { user: user, topic: topic, reply_to_message: parent,
            sender_alias: sender, identity: identity,
            subject: 'Re: hello', body: 'hi' }.merge(overrides))
  end

  it 'builds RFC822 with proper From, To, Subject, Body' do
    with_env('HACKORUM_OUTGOING_DOMAIN' => 'hackorum.local') do
      result = described_class.build(build_draft)
      mail = Mail.new(result.encoded)
      expect(mail.from).to include('a@b')
      expect(mail.to).to eq([ 'test@example.com' ])
      expect(mail.subject).to eq('Re: hello')
      expect(mail.body.to_s.strip).to eq('hi')
    end
  end

  it 'sets Message-Id with the configured outgoing domain' do
    with_env('HACKORUM_OUTGOING_DOMAIN' => 'hackorum.local') do
      result = described_class.build(build_draft)
      expect(result.message_id).to match(/\A<[0-9a-f-]{36}@hackorum.local>\z/)
      expect(Mail.new(result.encoded).message_id).to eq(result.message_id.gsub(/[<>]/, ''))
    end
  end

  it 'reuses the draft message id' do
    result = described_class.build(build_draft(rfc_message_id: '<fixed@x>'))
    expect(result.message_id).to eq('<fixed@x>')
    expect(Mail.new(result.encoded).message_id).to eq('fixed@x')
  end

  it 'falls back to default outgoing domain when env unset' do
    with_env('HACKORUM_OUTGOING_DOMAIN' => nil) do
      result = described_class.build(build_draft)
      expect(result.message_id).to end_with("@#{Outgoing::MessageBuilder::DEFAULT_DOMAIN}>")
    end
  end

  it 'sets In-Reply-To to parent message_id' do
    with_env('HACKORUM_OUTGOING_DOMAIN' => 'hackorum.local') do
      result = described_class.build(build_draft)
      mail = Mail.new(result.encoded)
      expect(mail.in_reply_to).to eq('parent-id@x')
    end
  end

  it 'walks the reply chain to build References' do
    grand = create(:message, topic: topic, message_id: '<grand@x>')
    parent.update!(reply_to: grand, reply_to_message_id: '<grand@x>')
    with_env('HACKORUM_OUTGOING_DOMAIN' => 'hackorum.local') do
      result = described_class.build(build_draft)
      mail = Mail.new(result.encoded)
      refs = mail.references
      refs = [ refs ] unless refs.is_a?(Array)
      expect(refs).to include('grand@x', 'parent-id@x')
    end
  end

  it 'quotes sender names with commas and parens' do
    sender.update!(name: 'Doe, John (PG)')
    mail = Mail.new(described_class.build(build_draft).encoded)
    expect(mail.from).to eq([ 'a@b' ])
    expect(mail[:from].display_names).to eq([ 'Doe, John (PG)' ])
  end

  it 'omits ancestors with nil message_id from References' do
    orphan = create(:message, topic: topic, message_id: nil)
    parent.update!(reply_to: orphan, reply_to_message_id: nil)
    with_env('HACKORUM_OUTGOING_DOMAIN' => 'hackorum.local') do
      result = described_class.build(build_draft)
      refs = Mail.new(result.encoded).references
      refs = [ refs ] unless refs.is_a?(Array)
      expect(refs).to contain_exactly('parent-id@x')
    end
  end

  it 'joins all recipients into Result#recipient' do
    allow(Outgoing::RecipientResolver).to receive(:for)
      .with(kind_of(OutgoingDraft))
      .and_return(recipients(to: [ 'a@x' ], cc: [ 'list@x', 'c@x' ]))
    with_env('HACKORUM_OUTGOING_DOMAIN' => 'hackorum.local') do
      result = described_class.build(build_draft)
      expect(result.recipient).to eq('a@x, list@x, c@x')
    end
  end

  it 'sets To and Cc headers from the resolver' do
    allow(Outgoing::RecipientResolver).to receive(:for)
      .with(kind_of(OutgoingDraft))
      .and_return(recipients(to: [ 'a@x' ], cc: [ 'list@x', 'c@x' ]))
    with_env('HACKORUM_OUTGOING_DOMAIN' => 'hackorum.local') do
      mail = Mail.new(described_class.build(build_draft).encoded)
      expect(mail.to).to eq([ 'a@x' ])
      expect(mail.cc).to eq([ 'list@x', 'c@x' ])
    end
  end

  it 'omits the Cc header when there are no cc recipients' do
    with_env('HACKORUM_OUTGOING_DOMAIN' => 'hackorum.local') do
      mail = Mail.new(described_class.build(build_draft).encoded)
      expect(mail.cc).to be_nil
    end
  end

  it 'sets text/plain content type' do
    with_env('HACKORUM_OUTGOING_DOMAIN' => 'hackorum.local') do
      result = described_class.build(build_draft)
      mail = Mail.new(result.encoded)
      expect(mail.content_type).to start_with('text/plain')
      expect(mail.content_type).to include('charset=UTF-8') | include('charset=utf-8')
    end
  end

  it 'stays single-part without attachments' do
    mail = Mail.new(described_class.build(build_draft).encoded)
    expect(mail.multipart?).to be false
    expect(mail.attachments).to be_empty
  end

  context 'with attachments' do
    let(:patch_bytes) { "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n" }
    let(:blob_bytes)  { (0..255).map(&:chr).join.b }

    def built_mail
      draft = build_draft
      create(:draft_attachment, outgoing_draft: draft, file_name: 'fix.patch',
             content_type: 'text/x-diff', content: patch_bytes)
      create(:draft_attachment, outgoing_draft: draft, file_name: 'blob.bin',
             content_type: nil, content: blob_bytes)
      Mail.new(described_class.build(draft).encoded)
    end

    it 'is multipart/mixed with the text part first' do
      mail = built_mail
      expect(mail.mime_type).to eq('multipart/mixed')
      text = mail.parts.first
      expect(text.mime_type).to eq('text/plain')
      expect(text.content_type_parameters['charset']).to match(/\Autf-8\z/i)
      expect(text.decoded.strip).to eq('hi')
    end

    it 'carries name, type and exact bytes of each file' do
      mail = built_mail
      expect(mail.attachments.map(&:filename)).to eq(%w[fix.patch blob.bin])

      patch, blob = mail.attachments
      expect(patch.mime_type).to eq('text/x-diff')
      expect(patch.decoded).to eq(patch_bytes)
      expect(blob.mime_type).to eq('application/octet-stream')
      expect(blob.decoded.b).to eq(blob_bytes)
    end
  end

  context 'with stored content types that would change the structure of the mail' do
    let(:payload) { "--abc\nContent-Type: text/plain\n\nread me as the message\n--abc--\n" }
    let(:hostile) {
      [ 'multipart/mixed; boundary=abc', 'Multipart/Alternative; boundary="abc"', 'message/rfc822',
        'text/plain; name="evil.exe"', 'text/plain; charset=utf-8; charset=utf-7', "text/plain\r\nX-Evil: 1",
        'text/html; boundary=abc; name=evil.exe', 'nonsense' ]
    }

    def leaves(part)
      part.multipart? ? part.parts.flat_map { |p| leaves(p) } : [ part ]
    end

    it 'has one text body and plain attachment parts, whatever the stored type says' do
      draft = build_draft(body: 'the real text')
      hostile.each do |type|
        draft.draft_attachments.delete_all
        2.times do |i|
          create(:draft_attachment, outgoing_draft: draft, file_name: "file#{i}.txt", content_type: type, content: payload)
        end

        raw = described_class.build(draft).encoded
        mail = Mail.new(raw)

        expect(mail.mime_type).to eq('multipart/mixed'), type
        expect(mail.parts.size).to eq(3), type
        expect(mail.parts.map(&:multipart?)).to all(be(false)), type
        expect(mail.parts.map(&:main_type)).not_to include('multipart', 'message'), type
        expect(leaves(mail).size).to eq(3), type

        text, *files = mail.parts
        expect(text.mime_type).to eq('text/plain'), type
        expect(text.content_disposition).to be_nil, type
        expect(text.decoded.strip).to eq('the real text'), type

        files.each_with_index do |part, i|
          expect(part.content_disposition).to start_with('attachment'), type
          expect(part.filename).to eq("file#{i}.txt"), type
          expect(part.header.fields.map(&:name)).to match_array(%w[Content-Type Content-Transfer-Encoding Content-Disposition]), type
          expect(part.content_type_parameters.to_h.keys - %w[charset]).to eq([]), type
          expect(part.decoded).to eq(payload), type
          expect(part.encoded.scan(/file#{i}\.txt/).size).to eq(1), type
        end
        expect(raw).not_to include('evil.exe', 'X-Evil', 'utf-7'), type
        expect(raw.scan(/^Content-Type: multipart/i).size).to eq(1), type
        expect(raw).not_to match(/^Content-Type: message/i), type
      end
    end

    it 'keeps a known charset of a text attachment' do
      draft = build_draft
      create(:draft_attachment, outgoing_draft: draft, file_name: 'a.txt',
             content_type: 'text/plain; charset=ISO-8859-1; name=x', content: 'abc')

      part = Mail.new(described_class.build(draft).encoded).attachments.sole

      expect(part.mime_type).to eq('text/plain')
      expect(part.content_type_parameters['charset']).to match(/\Aiso-8859-1\z/i)
    end
  end
end
