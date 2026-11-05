require "rails_helper"
require "rake"

RSpec.describe "staging:sanitize" do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["staging:sanitize"] }

  before { task.reenable }

  around do |example|
    old = ENV["HACKORUM_ENV"]
    example.run
  ensure
    ENV["HACKORUM_ENV"] = old
  end

  it "refuses outside staging" do
    ENV.delete("HACKORUM_ENV")
    expect { task.invoke }.to raise_error(SystemExit)
  end

  context "on staging" do
    before { ENV["HACKORUM_ENV"] = "staging" }

    it "resets sending drafts, sync state and queued jobs" do
      draft = create(:outgoing_draft, status: OutgoingDraft::STATUS_SENDING, sending_started_at: 1.minute.ago)
      ImapSyncState.for_label("INBOX")
      queue_tables = SolidQueue::Job.table_exists?
      SolidQueue::Job.create!(queue_name: "default", class_name: "ApplicationJob", arguments: {}) if queue_tables

      expected_jobs = queue_tables ? 1 : 0
      expect { task.invoke }.to output(/drafts=1 .*sync_states=1 .*jobs=#{expected_jobs}/).to_stdout

      expect(draft.reload.status).to eq(OutgoingDraft::STATUS_IDLE)
      expect(draft.last_send_error).to eq("Reset by staging restore")
      expect(draft.sending_started_at).to be_nil
      expect(ImapSyncState.count).to eq(0)
      expect(SolidQueue::Job.count).to eq(0) if queue_tables
    end

    it "is idempotent" do
      task.invoke
      task.reenable
      expect { task.invoke }.to output(/drafts=0 .*sync_states=0 .*jobs=0/).to_stdout
    end
  end
end
