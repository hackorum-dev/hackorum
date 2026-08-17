require "rails_helper"

RSpec.describe PatchCi::TopicStatus do
  let(:repo_state) { create(:patch_ci_repo_state, master_committed_at: Time.current) }
  let(:topic) { create(:topic) }

  def patchset(index, **attrs)
    message = create(:message, topic: topic, is_patch_submission: true)
    create(:patch_branch, topic: topic, message: message,
           branch_name: "t#{topic.id}_#{index}",
           base_sha: repo_state.master_sha, **attrs)
  end

  def status
    described_class.new(topic: topic, repo_state: repo_state)
  end

  it "reports nothing for a topic with no patchset" do
    expect(status.present?).to be(false)
  end

  it "carries the current patchset" do
    old = patchset(1)
    fresh = patchset(2)
    old.update!(superseded_by: fresh)

    expect(status.row.id).to eq(fresh.id)
  end

  it "has no image run when nothing built one" do
    patchset(1)

    expect(status.image_run).to be_nil
  end

  # last to finish pushing wins the tag, not the highest run id: a re-run
  # carries a higher attempt against an older run id
  it "picks the run that finished last, not the newest run id" do
    row = patchset(1)
    late = create(:patch_ci_run, patch_branch: row, github_run_id: 100,
                  image_ref: "ghcr.io/x/postgres:t1", completed_at: 1.hour.ago)
    create(:patch_ci_run, patch_branch: row, github_run_id: 900,
           image_ref: "ghcr.io/x/postgres:t1", completed_at: 3.hours.ago)

    expect(status.image_run.id).to eq(late.id)
  end

  it "ignores runs that built no image" do
    row = patchset(1)
    create(:patch_ci_run, patch_branch: row, github_run_id: 900, completed_at: Time.current)
    with_image = create(:patch_ci_run, patch_branch: row, github_run_id: 100,
                        image_ref: "ghcr.io/x/postgres:t1", completed_at: 2.hours.ago)

    expect(status.image_run.id).to eq(with_image.id)
  end

  it "calls the image current when the current patchset built it" do
    row = patchset(1)
    create(:patch_ci_run, patch_branch: row, image_ref: "ghcr.io/x/postgres:t1",
           completed_at: Time.current)

    expect(status.image_current?).to be(true)
  end

  it "calls the image stale when an older patchset built it" do
    old = patchset(1)
    fresh = patchset(2)
    old.update!(superseded_by: fresh)
    create(:patch_ci_run, patch_branch: old, image_ref: "ghcr.io/x/postgres:t1",
           completed_at: Time.current)

    expect(status.image_current?).to be(false)
    expect(status.image_branch.id).to eq(old.id)
    expect(status.image_branch.association(:message)).to be_loaded
  end
end
