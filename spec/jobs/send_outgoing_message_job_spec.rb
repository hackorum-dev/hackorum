require 'rails_helper'

RSpec.describe SendOutgoingMessageJob do
  let(:user)     { create(:user) }
  let(:identity) { create(:identity, user: user, email: 'a@b',
                          refresh_token: 'r', access_token: 'at',
                          access_token_expires_at: 1.hour.from_now) }
  let(:sender)   { create(:alias, user: user, name: 'Alice', email: 'a@b') }
  let(:list)     { create(:mailing_list, post_address: 'list@example.com') }
  let(:topic)    { create(:topic, mailing_lists: [list]) }
  let(:parent)   { create(:message, topic: topic, message_id: '<parent@x>') }
  let(:draft) {
    create(:outgoing_draft,
           user: user, topic: topic, reply_to_message: parent,
           sender_alias: sender, identity: identity,
           subject: 'Re: hi', body: 'hello',
           status: 'sending', sending_started_at: 1.second.ago)
  }

  let(:builder_result) {
    Outgoing::MessageBuilder::Result.new(
      encoded: "raw-encoded", message_id: "<m@x>",
      subject: "Re: hi", recipient: "to@x")
  }

  before do
    allow(OAuth::TokenRefresher).to receive(:call)
    allow(Outgoing::MessageBuilder).to receive(:build).with(draft).and_return(builder_result)
  end

  it 'creates a pending message and marks the draft sent on success' do
    allow(Gmail::SendClient).to receive(:send_raw).and_return({"id" => "g"})

    expect {
      described_class.new.perform(draft.id)
    }.to change(Message, :count).by(1)
     .and change(OutgoingDraft, :count).by(0)

    msg = Message.where(message_id: '<m@x>').first
    expect(msg).to be_present
    expect(msg.state).to eq(Message::STATE_PENDING)
    expect(msg.sent_to_address).to eq('to@x')
    expect(msg.sent_via_identity_id).to eq(identity.id)
    expect(msg.subject).to eq('Re: hi')
    expect(msg.body).to eq('hello')
    expect(msg.sender_id).to eq(sender.id)
    expect(msg.sender_person_id).to eq(sender.person_id)
    expect(msg.reply_to_id).to eq(parent.id)
    expect(msg.reply_to_message_id).to eq(parent.message_id)

    draft.reload
    expect(draft).to be_sent
    expect(draft.sent_message_id).to eq(msg.id)
    expect(draft.sent_at).to be_within(5.seconds).of(Time.current)
    expect(draft.last_send_error).to be_nil
  end

  it 'no-ops if the draft is already sent' do
    draft.update_columns(status: 'sent', sent_at: 1.minute.ago)
    expect(Gmail::SendClient).not_to receive(:send_raw)
    described_class.new.perform(draft.id)
  end

  it 'persists error and resets draft to idle on PermanentError' do
    allow(Gmail::SendClient).to receive(:send_raw).and_raise(Gmail::PermanentError, 'bad request')
    expect {
      described_class.new.perform(draft.id)
    }.not_to change(Message, :count)
    draft.reload
    expect(draft).to be_idle
    expect(draft.sending_started_at).to be_nil
    expect(draft.last_send_error).to include('bad request')
  end

  it 'revokes identity tokens on AuthRevokedError from send' do
    allow(Gmail::SendClient).to receive(:send_raw).and_raise(Gmail::AuthRevokedError, 'unauthorized')
    described_class.new.perform(draft.id)
    identity.reload
    expect(identity.send_revoked_at).not_to be_nil
    expect(identity.refresh_token).to be_nil
    expect(identity.access_token).to be_nil
    draft.reload
    expect(draft).to be_idle
    expect(draft.last_send_error).to include('unauthorized')
  end

  it 'lets TransientError propagate so ActiveJob can retry' do
    allow(Gmail::SendClient).to receive(:send_raw).and_raise(Gmail::TransientError, 'down')
    expect {
      expect { described_class.new.perform(draft.id) }.to raise_error(Gmail::TransientError)
    }.not_to change(Message, :count)
  end

  it 'no-ops if the draft is no longer in sending state' do
    draft.update!(status: 'idle')
    expect(Gmail::SendClient).not_to receive(:send_raw)
    described_class.new.perform(draft.id)
  end

  it 'no-ops if the draft was destroyed' do
    id = draft.id
    draft.destroy!
    expect(Gmail::SendClient).not_to receive(:send_raw)
    expect { described_class.new.perform(id) }.not_to raise_error
  end

  it 'configures retry_on for Gmail::TransientError' do
    handler_keys = described_class.rescue_handlers.map(&:first)
    expect(handler_keys).to include('Gmail::TransientError').or include(Gmail::TransientError)
  end
end
