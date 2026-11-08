require "rails_helper"

RSpec.describe PatchCi::Orchestrator do
  let(:master_sha) { "a" * 40 }
  let(:client) { instance_double(PatchCi::GithubClient, runs: [], in_flight_count: 0) }
  let(:pusher) { instance_double(PatchCi::Pusher) }
  let(:guard) { instance_double(PatchCi::PushGuard, check: nil) }
  let(:apply_one) { instance_double(PatchBranches::ApplyOne) }
  let(:fetch_result) { instance_double(PatchBranches::GitRepo::Result, success?: true) }
  let(:refs) { instance_double(PatchCi::ResultRefs, fetch!: fetch_result, payloads: {}) }
  let(:pruner) { instance_double(PatchCi::ResultRefPruner, prune!: 0) }
  let(:planner) { instance_double(PatchCi::Planner, plan: []) }
  let(:repo) do
    instance_double(PatchBranches::GitRepo, commit_time: Time.current, commit_height: 100_000)
  end
  let(:master_sync) do
    instance_double(PatchCi::MasterSync,
                    call: PatchCi::MasterSync::Result.new(sha: master_sha, fetch_failed: false,
                                                          mirror_error: nil))
  end

  before do
    allow(PatchCi::DashboardBroadcast).to receive(:refresh!)
  end

  def orchestrator(**opts)
    described_class.new(client: client, pusher: pusher, guard: guard, apply_one: apply_one,
                        result_refs: refs, pruner: pruner, repo: repo, master_sync: master_sync,
                        planner_factory: ->(_state) { planner }, **opts)
  end

  def backfill_item(row)
    PatchCi::Planner::WorkItem.new(kind: :backfill, patch_branch: row, message: row.message)
  end

  def github_run(id)
    PatchCi::GithubClient::Run.new(id: id, attempt: 1, branch: "t1_1", status: "completed",
                                   conclusion: "success", head_sha: "a" * 40)
  end

  def plans(*items)
    allow(planner).to receive(:plan).and_return(items)
  end

  it "refreshes the repo state from the sha master sync resolved" do
    orchestrator.cycle

    state = PatchCiRepoState.current
    expect(master_sync).to have_received(:call)
    expect(state.master_sha).to eq(master_sha)
    expect(state.master_commit_height).to eq(100_000)
  end

  it "reports a failed master fetch and carries on" do
    allow(master_sync).to receive(:call).and_return(
      PatchCi::MasterSync::Result.new(sha: master_sha, fetch_failed: true, mirror_error: nil)
    )

    result = orchestrator.cycle

    expect(result[:fetch_failed]).to be(true)
    expect(result[:error]).to be_nil
  end

  it "reports a failed mirror push and carries on" do
    allow(master_sync).to receive(:call).and_return(
      PatchCi::MasterSync::Result.new(sha: master_sha, fetch_failed: false,
                                      mirror_error: "Write access denied")
    )

    result = orchestrator.cycle

    expect(result[:mirror_error]).to eq("Write access denied")
    expect(result[:error]).to be_nil
  end

  # the mirror is resolved before anything that can raise, so a lost cycle
  # still has to report why the fork's master is not moving
  it "reports a failed mirror push even when the github fetch fails" do
    allow(master_sync).to receive(:call).and_return(
      PatchCi::MasterSync::Result.new(sha: master_sha, fetch_failed: false,
                                      mirror_error: "Write access denied")
    )
    allow(client).to receive(:runs).and_raise(PatchCi::GithubClient::Error, "boom")

    result = orchestrator.cycle

    expect(result[:mirror_error]).to eq("Write access denied")
    expect(result[:error]).to eq("boom")
  end

  it "does not re-read runs whose verdict the branch already took" do
    branch = create(:patch_branch, branch_name: "t1_1", pushed_head_sha: "a" * 40)
    run = create(:patch_ci_run, patch_branch: branch, github_run_id: 7, run_attempt: 1,
                                status: "success", head_sha: "a" * 40, payload: { "schema" => 1 })
    branch.update!(latest_ci_run_id: run.id)
    allow(client).to receive(:runs).and_return([ github_run(7), github_run(8) ])
    expect(refs).to receive(:payloads).with(only: [ 8 ]).and_return({})

    orchestrator.cycle
  end

  it "does not re-read a stored run whose sha the branch has moved past" do
    branch = create(:patch_branch, branch_name: "t1_1", pushed_head_sha: "b" * 40)
    create(:patch_ci_run, patch_branch: branch, github_run_id: 7, run_attempt: 1,
                          status: "success", head_sha: "a" * 40, payload: { "schema" => 1 })
    allow(client).to receive(:runs).and_return([ github_run(7) ])
    expect(refs).to receive(:payloads).with(only: []).and_return({})

    orchestrator.cycle
  end

  it "does not re-read a run a later re-run of the same sha replaced" do
    branch = create(:patch_branch, branch_name: "t1_1", pushed_head_sha: "a" * 40)
    create(:patch_ci_run, patch_branch: branch, github_run_id: 7, run_attempt: 1,
                          status: "success", head_sha: "a" * 40, payload: { "schema" => 1 })
    rerun = create(:patch_ci_run, patch_branch: branch, github_run_id: 8, run_attempt: 1,
                                  status: "success", head_sha: "a" * 40, payload: { "schema" => 1 })
    branch.update!(latest_ci_run_id: rerun.id)
    allow(client).to receive(:runs).and_return([ github_run(7), github_run(8) ])
    expect(refs).to receive(:payloads).with(only: []).and_return({})

    orchestrator.cycle
  end

  it "keeps a stored run the branch never promoted in the window" do
    # a push interrupted between git push and the row update: the re-push is
    # deterministic, so no new run appears and only a re-ingest can promote
    branch = create(:patch_branch, branch_name: "t1_1", pushed_head_sha: "a" * 40)
    create(:patch_ci_run, patch_branch: branch, github_run_id: 7, run_attempt: 1,
                          status: "success", head_sha: "a" * 40, payload: { "schema" => 1 })
    allow(client).to receive(:runs).and_return([ github_run(7) ])
    expect(refs).to receive(:payloads).with(only: [ 7 ]).and_return({})

    orchestrator.cycle
  end

  it "still re-reads a run whose payload never made it into the row" do
    branch = create(:patch_branch, branch_name: "t1_1", pushed_head_sha: "a" * 40)
    create(:patch_ci_run, patch_branch: branch, github_run_id: 7, run_attempt: 1,
                          status: "infra_error", payload: { "ingest_error" => "boom" })
    allow(client).to receive(:runs).and_return([ github_run(7) ])
    expect(refs).to receive(:payloads).with(only: [ 7 ]).and_return({})

    orchestrator.cycle
  end

  it "pushes up to the free slots" do
    rows = Array.new(3) { create(:patch_branch) }
    plans(*rows.map { |row| backfill_item(row) })
    expect(pusher).to receive(:push).exactly(3).times.and_return(true)

    result = orchestrator(budget: 5).cycle

    expect(result[:pushed]).to eq(3)
    expect(result[:free_slots]).to eq(5)
  end

  it "asks for three times the free slots so guard rejections do not waste them" do
    expect(planner).to receive(:plan).with(limit: 15).and_return([])

    orchestrator(budget: 5).cycle
  end

  it "stops executing once the free slots are filled" do
    rows = Array.new(3) { create(:patch_branch) }
    plans(*rows.map { |row| backfill_item(row) })
    expect(pusher).to receive(:push).once.and_return(true)

    expect(orchestrator(budget: 1).cycle[:pushed]).to eq(1)
  end

  it "pushes nothing when the budget is full" do
    allow(client).to receive(:in_flight_count).and_return(PatchCi::Config::BUDGET)
    expect(planner).not_to receive(:plan)
    expect(pusher).not_to receive(:push)

    expect(orchestrator.cycle[:free_slots]).to eq(0)
  end

  it "counts pushes github has not turned into runs yet against the budget" do
    create_list(:patch_branch, 3, ci_status: "pushed_awaiting_ci", pushed_at: 5.minutes.ago)
    create(:patch_branch, ci_status: "pushed_awaiting_ci", pushed_at: 1.day.ago)
    expect(planner).to receive(:plan).with(limit: 6).and_return([])

    result = orchestrator(budget: 5).cycle

    expect(result).to include(in_flight: 3, unseen: 3, free_slots: 2)
  end

  it "never reports negative free slots" do
    allow(client).to receive(:in_flight_count).and_return(PatchCi::Config::BUDGET + 7)

    expect(orchestrator.cycle[:free_slots]).to eq(0)
  end

  it "pushes nothing when the API call fails" do
    allow(client).to receive(:runs).and_raise(PatchCi::GithubClient::Error, "403")
    expect(pusher).not_to receive(:push)
    expect(planner).not_to receive(:plan)

    result = orchestrator.cycle

    expect(result).to include(pushed: 0, in_flight: nil, free_slots: 0, refs_stale: true)
    expect(result[:error]).to include("403")
  end

  it "pushes nothing when in_flight_count fails" do
    allow(client).to receive(:in_flight_count).and_raise(PatchCi::GithubClient::Error, "rate limited")
    expect(pusher).not_to receive(:push)
    expect(planner).not_to receive(:plan)

    result = orchestrator.cycle

    expect(result[:pushed]).to eq(0)
    expect(result[:error]).to include("rate limited")
  end

  it "skips ingestion, marking and pruning when the ref fetch fails" do
    allow(fetch_result).to receive(:success?).and_return(false)
    expect(refs).not_to receive(:payloads)
    expect(PatchCi::StuckRunMarker).not_to receive(:new)
    expect(pruner).not_to receive(:prune!)

    result = nil
    expect { result = orchestrator.cycle }.to output(/result refs stale \(ref fetch failed\)/).to_stderr

    expect(result[:refs_stale]).to eq(true)
    expect(result[:ingested]).to eq({})
    expect(result[:pruned]).to eq(0)
    expect(result[:error]).to be_nil
  end

  it "skips ingestion, marking and pruning when the payload read signals trouble" do
    row = create(:patch_branch)
    plans(backfill_item(row))
    allow(refs).to receive(:payloads).and_raise(PatchCi::ResultRefs::ReadError, "truncated")
    expect(PatchCi::StuckRunMarker).not_to receive(:new)
    expect(pruner).not_to receive(:prune!)
    expect(pusher).to receive(:push).and_return(true)

    result = nil
    expect { result = orchestrator.cycle }.to output(/result refs stale \(truncated\)/).to_stderr

    expect(result[:refs_stale]).to eq(true)
    expect(result[:ingested]).to eq({})
    expect(result[:pushed]).to eq(1)
  end

  it "marks stuck runs and prunes refs on a healthy cycle" do
    marker = instance_double(PatchCi::StuckRunMarker, call: 0)
    allow(PatchCi::StuckRunMarker).to receive(:new).and_return(marker)
    allow(pruner).to receive(:prune!).and_return(4)

    expect(marker).to receive(:call)
    expect(orchestrator.cycle[:pruned]).to eq(4)
  end

  it "clears stranded era skips and reports the count" do
    reset = instance_double(PatchCi::EraSkipReset, call: 7)
    allow(PatchCi::EraSkipReset).to receive(:new).and_return(reset)

    expect(orchestrator.cycle[:era_skips_cleared]).to eq(7)
  end

  # an era image landing has to unstrand its rows even while the API is down,
  # so this runs ahead of anything that can raise GithubClient::Error
  it "clears stranded era skips even when the github fetch fails" do
    reset = instance_double(PatchCi::EraSkipReset, call: 3)
    allow(PatchCi::EraSkipReset).to receive(:new).and_return(reset)
    allow(client).to receive(:runs).and_raise(PatchCi::GithubClient::Error, "boom")

    result = orchestrator.cycle
    expect(result[:error]).to eq("boom")
    expect(result[:era_skips_cleared]).to eq(3)
  end

  it "broadcasts once per cycle" do
    expect(PatchCi::DashboardBroadcast).to receive(:refresh!).once

    orchestrator.cycle
  end

  describe "new_version items" do
    let(:topic) { create(:topic) }
    let(:message) { create(:message, topic: topic, is_patch_submission: true) }
    let!(:old_row) { create(:patch_branch, topic: topic, pushed_at: 1.day.ago) }
    let(:new_row) { create(:patch_branch, topic: topic, message: message) }

    before do
      plans(PatchCi::Planner::WorkItem.new(kind: :new_version, message: message))
    end

    it "applies, pushes and supersedes the older rows" do
      allow(apply_one).to receive(:call).with(message.id, master_sha: master_sha)
                                       .and_return([ :applied_on_master, new_row ])
      expect(pusher).to receive(:push).with(new_row).and_return(true)

      expect(orchestrator.cycle[:pushed]).to eq(1)
      expect(old_row.reload.superseded_by_id).to eq(new_row.id)
    end

    it "leaves lineage-only rows alone when superseding" do
      lineage = create(:patch_branch, topic: topic, lineage_only: true)
      allow(apply_one).to receive(:call).and_return([ :applied_on_master, new_row ])
      allow(pusher).to receive(:push).and_return(true)

      expect(orchestrator.cycle[:pushed]).to eq(1)
      expect(old_row.reload.superseded_by_id).to eq(new_row.id)
      expect(lineage.reload.superseded_by_id).to be_nil
    end

    it "does not supersede when the push fails" do
      allow(apply_one).to receive(:call).and_return([ :applied_on_master, new_row ])
      allow(pusher).to receive(:push).and_return(false)

      expect(orchestrator.cycle[:pushed]).to eq(0)
      expect(old_row.reload.superseded_by_id).to be_nil
    end

    it "pushes nothing when the apply did not produce an applied row" do
      failed = create(:patch_branch, topic: topic, message: message, status: "failed")
      allow(apply_one).to receive(:call).and_return([ :apply_failed, failed ])
      expect(pusher).not_to receive(:push)

      expect(orchestrator.cycle[:pushed]).to eq(0)
      expect(old_row.reload.superseded_by_id).to be_nil
    end

    it "pushes nothing when the apply returned no row" do
      allow(apply_one).to receive(:call).and_return([ :extract_failed, nil ])
      expect(pusher).not_to receive(:push)

      expect(orchestrator.cycle[:pushed]).to eq(0)
    end

    it "records the guard's refusal on the fresh row instead of pushing" do
      allow(apply_one).to receive(:call).and_return([ :applied_on_master, new_row ])
      allow(guard).to receive(:check).and_return("patchset touches .github/")
      expect(pusher).to receive(:skip).with(new_row, "patchset touches .github/")
      expect(pusher).not_to receive(:push)

      expect(orchestrator.cycle[:pushed]).to eq(0)
      expect(old_row.reload.superseded_by_id).to be_nil
    end
  end

  describe "rebase items" do
    let(:row) { create(:patch_branch, pushed_at: 1.day.ago) }

    before do
      plans(PatchCi::Planner::WorkItem.new(kind: :rebase, patch_branch: row, message: row.message))
    end

    it "pushes the refreshed row when the master probe applies" do
      allow(apply_one).to receive(:call)
        .with(row.message_id, master_sha: master_sha, master_only: true)
        .and_return([ :applied_on_master, row ])
      # written behind the in-memory row's back: only a reload sees it
      PatchBranch.where(id: row.id).update_all(base_sha: master_sha)
      expect(pusher).to receive(:push).with(having_attributes(base_sha: master_sha)).and_return(true)

      expect(orchestrator.cycle[:pushed]).to eq(1)
    end

    # an infra failure writes nothing to the row, so the cycle line is the only
    # place it can show up - and a worktree that has stopped applying anything
    # must not look like a quiet cycle
    it "counts an infra failure as a failed item and names it" do
      allow(apply_one).to receive(:call).and_return([ :infra_failed, row ])
      expect(pusher).not_to receive(:push)

      result = nil
      expect { result = orchestrator.cycle }.to output(/infra failure/).to_stderr

      expect(result).to include(pushed: 0, failed: 1)
    end

    it "pushes nothing when the master probe fails" do
      allow(apply_one).to receive(:call).and_return([ :master_apply_failed, row ])
      expect(pusher).not_to receive(:push)

      expect(orchestrator.cycle[:pushed]).to eq(0)
    end

    it "pushes nothing when the row vanished between plan and execute" do
      allow(apply_one).to receive(:call).and_return([ :skipped, row ])
      expect(pusher).not_to receive(:push)

      expect(orchestrator.cycle[:pushed]).to eq(0)
    end

    it "pushes nothing when the base is already current" do
      allow(apply_one).to receive(:call).and_return([ :already_current, row ])
      expect(pusher).not_to receive(:push)

      expect(orchestrator.cycle[:pushed]).to eq(0)
    end

    it "records the guard's refusal after a successful probe" do
      allow(apply_one).to receive(:call).and_return([ :applied_on_master, row ])
      allow(guard).to receive(:check).and_return("no era image for pg16")
      expect(pusher).to receive(:skip).with(row, "no era image for pg16")
      expect(pusher).not_to receive(:push)

      expect(orchestrator.cycle[:pushed]).to eq(0)
    end
  end

  describe "superseding" do
    let(:topic) { create(:topic) }
    let(:old_message) { create(:message, topic: topic, is_patch_submission: true, created_at: 3.days.ago) }
    let(:new_message) { create(:message, topic: topic, is_patch_submission: true, created_at: 1.day.ago) }
    let(:old_row) { create(:patch_branch, topic: topic, message: old_message, pushed_at: 2.days.ago) }
    let(:new_row) { create(:patch_branch, topic: topic, message: new_message) }

    before { allow(pusher).to receive(:push).and_return(true) }

    it "retires the older rows when the newest patchset is pushed" do
      old_row
      plans(backfill_item(new_row))

      orchestrator.cycle

      expect(old_row.reload.superseded_by_id).to eq(new_row.id)
    end

    it "does not push a second row of the same topic behind the first" do
      # the guard only sees the supersede the first push wrote if the row is
      # re-read: the planned copy still says superseded_by_id nil
      plans(backfill_item(new_row), backfill_item(old_row))
      allow(guard).to receive(:check) { |row| row.superseded_by_id ? "row superseded" : nil }
      expect(pusher).to receive(:push).with(new_row).and_return(true)
      expect(pusher).to receive(:skip).with(old_row, "row superseded")

      expect(orchestrator.cycle[:pushed]).to eq(1)
    end

    it "leaves the rows alone when an older patchset is pushed" do
      new_row
      plans(backfill_item(old_row))

      orchestrator.cycle

      expect(new_row.reload.superseded_by_id).to be_nil
      expect(old_row.reload.superseded_by_id).to be_nil
    end
  end

  it "records the guard's refusal instead of pushing" do
    row = create(:patch_branch)
    plans(backfill_item(row))
    allow(guard).to receive(:check).and_return("no era image for pg16")
    expect(pusher).to receive(:skip).with(row, "no era image for pg16")
    expect(pusher).not_to receive(:push)

    expect(orchestrator.cycle[:pushed]).to eq(0)
  end

  it "caps total pushes across cycles with max_pushes" do
    rows = Array.new(2) { create(:patch_branch) }
    plans(*rows.map { |row| backfill_item(row) })
    allow(pusher).to receive(:push).and_return(true)

    runner = orchestrator(max_pushes: 1)

    expect(runner.cycle[:pushed]).to eq(1)
    second = runner.cycle
    expect(second[:pushed]).to eq(0)
    expect(second[:free_slots]).to eq(0)
    expect(pusher).to have_received(:push).once
  end

  it "keeps ingesting after max_pushes is spent" do
    runner = orchestrator(max_pushes: 0)
    expect(refs).to receive(:payloads).with(only: []).and_return({})
    expect(planner).not_to receive(:plan)

    expect(runner.cycle[:refs_stale]).to eq(false)
  end

  it "survives an item that blows up, counts it and continues with the next" do
    bad, good = create(:patch_branch), create(:patch_branch)
    plans(backfill_item(bad), backfill_item(good))
    allow(guard).to receive(:check).with(bad).and_raise("git exploded")
    allow(guard).to receive(:check).with(good).and_return(nil)
    expect(pusher).to receive(:push).with(good).and_return(true)

    result = nil
    expect { result = orchestrator.cycle }.to output(/1 item\(s\) failed this cycle.*git exploded/).to_stderr

    expect(result).to include(pushed: 1, failed: 1)
  end

  it "records an apply exception on the row and keeps going" do
    row = create(:patch_branch, pushed_at: 1.day.ago)
    plans(PatchCi::Planner::WorkItem.new(kind: :rebase, patch_branch: row, message: row.message))
    allow(apply_one).to receive(:call).and_raise("worktree gone")
    expect(apply_one).to receive(:persist_error).with(an_instance_of(RuntimeError)).and_return(nil)
    expect(pusher).not_to receive(:push)

    result = nil
    expect { result = orchestrator.cycle }.to output(/worktree gone/).to_stderr

    expect(result).to include(pushed: 0, failed: 1)
  end

  describe "dry run" do
    let!(:state) { create(:patch_ci_repo_state) }

    it "ingests but executes, prunes, marks and broadcasts nothing" do
      row = create(:patch_branch)
      plans(backfill_item(row))
      expect(refs).to receive(:payloads).with(only: []).and_return({})
      expect(apply_one).not_to receive(:call)
      expect(pusher).not_to receive(:push)
      expect(pusher).not_to receive(:skip)
      expect(pruner).not_to receive(:prune!)
      expect(PatchCi::StuckRunMarker).not_to receive(:new)
      expect(PatchCi::EraSkipReset).not_to receive(:new)
      expect(PatchCi::DashboardBroadcast).not_to receive(:refresh!)

      result = nil
      expect { result = orchestrator(dry_run: true).cycle }
        .to output(/\[dry-run\] backfill #{row.branch_name}/).to_stdout

      expect(result[:pushed]).to eq(0)
      expect(result[:refs_stale]).to eq(false)
    end

    it "does not fetch when a repo state row already exists" do
      orchestrator(dry_run: true).cycle

      expect(master_sync).not_to have_received(:call)
    end

    it "still fetches on the very first run" do
      state.destroy!

      orchestrator(dry_run: true).cycle

      expect(master_sync).to have_received(:call)
    end
  end

  describe "slug sync" do
    let(:slug_sync) { instance_double(PatchCi::SlugSync) }

    it "survives an exception" do
      allow(slug_sync).to receive(:call).and_raise(ActiveRecord::ConnectionNotEstablished, "db gone")

      result = orchestrator(slug_sync: slug_sync).cycle

      expect(result[:failed]).to eq(1)
      expect(result[:error]).to be_nil
      expect(result[:slugs_synced]).to be(false)
    end

    it "runs each cycle" do
      allow(slug_sync).to receive(:call).and_return(PatchCi::SlugSync::Result.new(pushed: true))

      result = orchestrator(slug_sync: slug_sync).cycle

      expect(slug_sync).to have_received(:call).once
      expect(result[:slugs_synced]).to be(true)
    end

    it "is skipped on a dry run" do
      allow(slug_sync).to receive(:call)

      orchestrator(slug_sync: slug_sync, dry_run: true).cycle

      expect(slug_sync).not_to have_received(:call)
    end

    it "counts a failure without aborting the cycle" do
      allow(slug_sync).to receive(:call)
        .and_return(PatchCi::SlugSync::Result.new(pushed: false, error: "push failed: nope"))

      result = orchestrator(slug_sync: slug_sync).cycle

      expect(result[:failed]).to eq(1)
      expect(result[:error]).to be_nil
      expect(result[:slugs_synced]).to be(false)
    end
  end
end
