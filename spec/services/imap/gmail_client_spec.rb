# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Imap::GmailClient, type: :service do
  let(:imap_double) { instance_double(Net::IMAP) }

  before do
    allow(Net::IMAP).to receive(:new).and_return(imap_double)
    allow(imap_double).to receive(:login)
    allow(imap_double).to receive(:select)
  end

  it 'connects and selects configured label' do
    client = described_class.new(username: 'u', password: 'p', mailbox: 'list-mail')
    expect(imap_double).to receive(:select).with('list-mail')
    client.connect!
    expect(client.connected?).to be true
    expect(client.selected_mailbox).to eq('list-mail')
  end

  it 'searches for UIDs greater than last_uid' do
    client = described_class.new(username: 'u', password: 'p', mailbox: 'list-mail')
    client.connect!
    expect(imap_double).to receive(:uid_search).with([ "UID", "101:*" ]).and_return([ 101, 102 ])
    uids = client.uid_search_greater_than(100)
    expect(uids).to eq([ 101, 102 ])
  end

  it 'fetches RFC822 by UID' do
    client = described_class.new(username: 'u', password: 'p', mailbox: 'list-mail')
    client.connect!
    fetch_resp = [ double('Data', attr: { 'RFC822' => "raw message" }) ]
    expect(imap_double).to receive(:uid_fetch).with(123, 'RFC822').and_return(fetch_resp)
    raw = client.uid_fetch_rfc822(123)
    expect(raw).to eq('raw message')
  end

  it 'marks a message as seen' do
    client = described_class.new(username: 'u', password: 'p', mailbox: 'list-mail')
    client.connect!
    expect(imap_double).to receive(:uid_store).with(123, '+FLAGS.SILENT', [ :Seen ])
    expect(client.mark_seen(123)).to be true
  end

  it 'runs an idle cycle and yields responses when activity occurs' do
    client = described_class.new(username: 'u', password: 'p', mailbox: 'list-mail')
    client.connect!
    # Simulate Net::IMAP#idle with yielding one response
    allow(imap_double).to receive(:respond_to?).with(:idle).and_return(true)
    allow(imap_double).to receive(:idle_done)
    allow(Thread).to receive(:new).and_wrap_original do |m, *args, &blk|
      blk.call
      double('Thread', join: true)
    end
    yielded = []
    expect(imap_double).to receive(:idle) do |timeout, &blk|
      blk.call(double('Resp', name: 'EXISTS', data: 1))
    end
    result = client.idle_once(timeout: 1) { |resp| yielded << resp }
    expect(result).to eq(:activity)
    expect(yielded.size).to eq(1)
  end
end
