require "rails_helper"

RSpec.describe PatchCi::CommitCutoff do
  def row(message_at:, last_commit_at:)
    topic = create(:topic, last_commit_at: last_commit_at)
    create(:patch_branch, topic: topic,
                          message: create(:message, topic: topic, created_at: message_at))
  end

  def live_ids
    described_class.live(PatchBranch.joins(:topic, :message)).pluck(:id)
  end

  it "keeps a patchset sent after the thread landed" do
    kept = row(message_at: 1.day.ago, last_commit_at: 3.days.ago)

    expect(live_ids).to eq([ kept.id ])
  end

  it "drops a patchset sent before the thread landed" do
    row(message_at: 5.days.ago, last_commit_at: 3.days.ago)

    expect(live_ids).to be_empty
  end

  # the boundary is <=, so a patch mailed in the same instant as the commit is
  # the patch that landed, not a follow-up to it
  it "drops a patchset sent at the moment the thread landed" do
    at = 3.days.ago
    row(message_at: at, last_commit_at: at)

    expect(live_ids).to be_empty
  end

  # the load bearing case: NOT (NULL comparison) would be unknown, not true,
  # and every uncommitted thread in the archive would vanish from the pipeline
  it "keeps every patchset of a thread that never landed" do
    kept = row(message_at: 5.days.ago, last_commit_at: nil)

    expect(live_ids).to eq([ kept.id ])
  end
end
