require "rails_helper"

RSpec.describe PatchBranch do
  it "is valid with the factory defaults" do
    expect(build(:patch_branch)).to be_valid
  end

  it "rejects unknown statuses" do
    expect(build(:patch_branch, status: "bogus")).not_to be_valid
  end

  it "rejects unknown failure stages" do
    expect(build(:patch_branch, status: "failed", failure_stage: "bogus")).not_to be_valid
  end

  it "round-trips conflict_files as a string array" do
    pb = create(:patch_branch, status: "failed", failure_stage: "apply",
                conflict_files: [ "src/a.c", "src/b.c" ])
    expect(pb.reload.conflict_files).to eq([ "src/a.c", "src/b.c" ])
  end

  it "enforces one branch per message" do
    pb = create(:patch_branch)
    dup = build(:patch_branch, message: pb.message, topic: pb.topic)
    expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "allows a nil ci_status" do
    expect(build(:patch_branch, ci_status: nil)).to be_valid
  end

  it "rejects an unknown ci_status" do
    expect(build(:patch_branch, ci_status: "bogus")).not_to be_valid
  end

  it "accepts a ci_status from PatchCiRun::STATUSES" do
    expect(build(:patch_branch, ci_status: "queued")).to be_valid
  end

  it "pushed scope returns only rows with a pushed_at" do
    pushed = create(:patch_branch, pushed_at: Time.current)
    create(:patch_branch, pushed_at: nil)
    expect(PatchBranch.pushed).to contain_exactly(pushed)
  end

  # the two dashboard sections split the branch statuses between them; anything
  # outside both never reaches either list, so make that set an explicit choice
  it "leaves only ci_none and push_failed out of both dashboard scopes" do
    covered = PatchCiRun::IN_FLIGHT_BRANCH_STATUSES + PatchCiRun::TERMINAL_STATUSES
    expect(PatchCiRun::STATUSES - covered).to eq(%w[ci_none push_failed])
  end

  # nil means "no run"; a row that never went through BranchRows must not be
  # able to render as one
  it "raises when the run summary was never attached" do
    row = build(:patch_branch)

    expect { row.latest_run_summary }.to raise_error(/not attached/)

    row.latest_run_summary = nil

    expect(row.latest_run_summary).to be_nil
  end

  it "does not require a latest_ci_run" do
    expect(build(:patch_branch, latest_ci_run: nil)).to be_valid
  end

  describe ".current and behind math" do
    it "current excludes superseded rows" do
      old = create(:patch_branch)
      new_row = create(:patch_branch, topic: old.topic)
      old.update!(superseded_by: new_row)
      expect(described_class.current).to include(new_row)
      expect(described_class.current).not_to include(old)
    end

    it "behind_commits/behind_days against a repo state" do
      travel_to Time.current do
        state = PatchCiRepoState.refresh!(master_sha: "a" * 40,
                                          master_committed_at: Time.current,
                                          master_commit_height: 1000)
        row = create(:patch_branch, base_commit_height: 900,
                     base_committed_at: 10.days.ago)
        expect(row.behind_commits(state)).to eq(100)
        expect(row.behind_days(state)).to eq(10)
        expect(row.behind_commits(nil)).to be_nil
        expect(create(:patch_branch).behind_commits(state)).to be_nil
      end
    end
  end

  describe ".current" do
    it "excludes lineage_only branches" do
      live = create(:patch_branch)
      create(:patch_branch, lineage_only: true)
      expect(PatchBranch.current).to contain_exactly(live)
    end
  end
end
