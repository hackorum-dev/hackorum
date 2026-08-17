require "rails_helper"

RSpec.describe PatchCi::CurrentPatchsets do
  let(:repo_state) { create(:patch_ci_repo_state, master_committed_at: Time.current) }
  let(:topic) { create(:topic) }

  def patchset(index, **attrs)
    message = create(:message, topic: topic, is_patch_submission: true)
    create(:patch_branch, topic: topic, message: message,
           branch_name: "t#{topic.id}_#{index}",
           base_sha: repo_state.master_sha, **attrs)
  end

  def load(ids)
    described_class.new(repo_state: repo_state).load(ids)
  end

  it "keys the current patchset by topic id" do
    row = patchset(1)

    expect(load([ topic.id ])[topic.id].id).to eq(row.id)
  end

  it "leaves out a topic with no patchset" do
    other = create(:topic)
    patchset(1)

    expect(load([ topic.id, other.id ]).keys).to eq([ topic.id ])
  end

  # the superseded row deliberately carries the HIGHER id: without
  # PatchBranch.current the id DESC tiebreak hands back exactly this row, so
  # the example dies the moment the scope does
  it "never returns a superseded patchset" do
    current = patchset(1)
    superseded = patchset(2)
    superseded.update!(superseded_by: current)

    expect(load([ topic.id ])[topic.id].id).to eq(current.id)
  end

  it "decorates the row with bucket, reason and base tier" do
    patchset(1, pushed_at: 1.hour.ago, ci_status: "success",
             base_committed_at: 1.day.ago, base_commit_height: 10)

    row = load([ topic.id ])[topic.id]

    expect(row.health_bucket).to eq("applies")
    expect(row.base_tier).to eq("recent")
    expect(row.wont_retry_reason).to eq("base too old")
  end

  it "attaches the promoted run as the row summary" do
    row = patchset(1)
    run = create(:patch_ci_run, patch_branch: row, tests_total: 229)
    row.update_columns(latest_ci_run_id: run.id)

    expect(load([ topic.id ])[topic.id].latest_run_summary.tests_total).to eq(229)
  end

  it "returns an empty hash without querying for an empty list" do
    repo_state # the let is lazy, and creating it inside the block would count
    queries = 0
    callback = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }

    result = nil
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { result = load([]) }

    expect(result).to eq({})
    expect(queries).to eq(0)
  end
end
