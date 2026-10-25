require 'rails_helper'

RSpec.describe ResetStaleSendingDraftsJob do
  it 'resets drafts stuck in sending older than 20 minutes' do
    fresh = create(:outgoing_draft, status: 'sending', sending_started_at: 1.minute.ago)
    stale = create(:outgoing_draft, status: 'sending', sending_started_at: 1.hour.ago)
    described_class.new.perform
    expect(fresh.reload).to be_sending
    expect(stale.reload).to be_idle
    expect(stale.last_send_error).to include('stuck')
    expect(stale.sending_started_at).to be_nil
  end

  it 'leaves idle drafts alone' do
    idle = create(:outgoing_draft, status: 'idle')
    described_class.new.perform
    expect(idle.reload).to be_idle
    expect(idle.last_send_error).to be_nil
  end

  it 'is a no-op when there are no stale drafts' do
    create(:outgoing_draft, status: 'sending', sending_started_at: 1.minute.ago)
    expect { described_class.new.perform }.not_to change(OutgoingDraft, :count)
  end

  it 'uses strict-less-than at the boundary' do
    travel_to(Time.current) do
      at_threshold = create(:outgoing_draft, status: 'sending',
                            sending_started_at: 20.minutes.ago)
      one_second_past = create(:outgoing_draft, status: 'sending',
                               sending_started_at: 20.minutes.ago - 1.second)
      described_class.new.perform
      expect(at_threshold.reload).to be_sending,
        'a row with sending_started_at == threshold is NOT stale (strict <)'
      expect(one_second_past.reload).to be_idle
    end
  end
end
