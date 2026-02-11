# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ImapIdleRunner, type: :service do
  let(:imap_client) { instance_double(Imap::GmailClient) }

  before do
    # Ensure the advisory lock yields in tests
    allow(AdvisoryLock).to receive(:with_lock).and_wrap_original do |m, *args, &blk|
      blk.call
    end
  end

    it 'processes new UIDs, marks seen, and updates last_uid' do
      state = ImapSyncState.for_label('INBOX')
      expect(state.last_uid).to eq(0)

      # IMAP interactions
      allow(imap_client).to receive(:connect!).and_return(true)
      allow(imap_client).to receive(:disconnect!).and_return(true)
    expect(imap_client).to receive(:uids_after).with(0).and_return([ 101 ])
    # Build a small raw email
    raw = <<~MAIL
      From: Test <test@example.com>
      To: You <you@example.com>
      Subject: Hello
      Date: Fri, 1 Jan 2021 12:00:00 +0000
      Message-ID: <uid-101@example.com>
      MIME-Version: 1.0
      Content-Type: text/plain; charset=UTF-8

      Body
    MAIL
      expect(imap_client).to receive(:uid_fetch_rfc822).with(101).and_return(raw)
      expect(imap_client).to receive(:mark_seen).with(101)
      # After first catch-up, idle once and timeout, then incremental sync finds nothing
      expect(imap_client).to receive(:idle_once).and_return(:timeout)
    allow(imap_client).to receive(:uids_after).with(101).and_return([])

      runner = described_class.new(client: imap_client, label: 'INBOX')
      runner.run(max_cycles: 1, idle_timeout: 1)

      state.reload
      expect(state.last_uid).to eq(101)
      # Mail.message_id returns value without angle brackets; DB stores it likewise
      expect(Message.find_by(message_id: 'uid-101@example.com')).to be_present
    end
end
