require "rails_helper"

RSpec.describe FeedEvent, type: :model do
  let(:message) { create(:message) }

  def insert(attrs)
    described_class.insert_all([ { occurred_at: Time.current, created_at: Time.current }.merge(attrs) ])
  end

  it "knows the four event types" do
    expect(described_class::TYPES).to eq(%w[message.received patchset.posted branch.created ci.completed])
  end

  it "rejects an unknown type" do
    expect(described_class.new(event_type: "nope", occurred_at: Time.current)).not_to be_valid
  end

  it "keeps one row per type and message" do
    2.times { insert(event_type: "message.received", message_id: message.id) }
    insert(event_type: "patchset.posted", message_id: message.id)

    expect(described_class.where(message_id: message.id).pluck(:event_type))
      .to contain_exactly("message.received", "patchset.posted")
  end

  it "keeps one row per branch and per run next to the message rows" do
    branch = create(:patch_branch, message: message, topic: message.topic)
    run = create(:patch_ci_run, patch_branch: branch)
    insert(event_type: "message.received", message_id: message.id)
    2.times { insert(event_type: "branch.created", message_id: message.id, patch_branch_id: branch.id) }
    2.times do
      insert(event_type: "ci.completed", message_id: message.id, patch_branch_id: branch.id,
             patch_ci_run_id: run.id)
    end

    expect(described_class.where(message_id: message.id).pluck(:event_type))
      .to contain_exactly("message.received", "branch.created", "ci.completed")
  end

  it "vanishes with its run, branch and message" do
    branch = create(:patch_branch, message: message, topic: message.topic)
    run = create(:patch_ci_run, patch_branch: branch)
    insert(event_type: "message.received", message_id: message.id)
    insert(event_type: "branch.created", message_id: message.id, patch_branch_id: branch.id)
    insert(event_type: "ci.completed", message_id: message.id, patch_branch_id: branch.id,
           patch_ci_run_id: run.id)

    expect { PatchCiRun.where(id: run.id).delete_all }.to change(described_class, :count).by(-1)
    expect { PatchBranch.where(id: branch.id).delete_all }.to change(described_class, :count).by(-1)
    message.topic.update_columns(last_message_id: nil)
    expect { Message.where(id: message.id).delete_all }.to change(described_class, :count).by(-1)
  end
end
