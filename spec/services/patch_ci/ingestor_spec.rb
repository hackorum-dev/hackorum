require "rails_helper"

RSpec.describe PatchCi::Ingestor do
  let(:branch) { create(:patch_branch, branch_name: "t1_1", pushed_head_sha: "a" * 40) }

  def run(status:, conclusion: nil, id: 7, head_sha: "a" * 40)
    PatchCi::GithubClient::Run.new(
      id: id, attempt: 1, branch: "t1_1", status: status, conclusion: conclusion,
      head_sha: head_sha, queued_at: "2026-07-26T10:00:00Z",
      started_at: "2026-07-26T10:01:00Z",
      completed_at: (status == "completed" ? "2026-07-26T10:15:00Z" : nil)
    )
  end

  def payload(status: "success", run_id: 7, executed: nil)
    tests = { ok: status == "success", seconds: 200,
              failed: status == "success" ? [] : [ "regress/foo" ] }
    tests[:executed] = executed if executed
    {
      schema: 1, branch: "t1_1", run_id: run_id, run_attempt: 1,
      head_sha: "a" * 40, base_sha: "b" * 40, pg_major: 20, status: status,
      build: { ok: true, seconds: 100 },
      tests: tests,
      image: { ref: "ghcr.io/x/postgres-patch:t1", digest: "sha256:#{"d" * 64}" },
      ccache: { hit: 10, miss: 2 }
    }.to_json
  end

  it "records an in flight run without a payload" do
    branch
    described_class.new(payloads: {}).ingest([ run(status: "in_progress") ])

    record = PatchCiRun.find_by(github_run_id: 7)
    expect(record.status).to eq("running")
    expect(record.patch_branch_id).to eq(branch.id)
    expect(branch.reload.ci_status).to eq("running")
  end

  it "takes the status from the payload when the run completed" do
    branch
    described_class.new(payloads: { 7 => payload(status: "tests_failed") })
      .ingest([ run(status: "completed", conclusion: "failure") ])

    record = PatchCiRun.find_by(github_run_id: 7)
    expect(record.status).to eq("tests_failed")
    expect(record.failed_tests).to eq([ "regress/foo" ])
    expect(record.image_ref).to eq("ghcr.io/x/postgres-patch:t1")
    expect(record.build_seconds).to eq(100)
    expect(branch.reload.ci_status).to eq("tests_failed")
    expect(branch.latest_ci_run_id).to eq(record.id)
    expect(record.tests_total).to be_nil
  end

  it "stores tests_total from the payload's executed list" do
    branch
    described_class.new(payloads: { 7 => payload(status: "success", executed: %w[regress/a regress/b regress/c]) })
      .ingest([ run(status: "completed", conclusion: "success") ])

    record = PatchCiRun.find_by(github_run_id: 7)
    expect(record.tests_total).to eq(3)
  end

  it "leaves tests_total nil when the payload has no executed list" do
    branch
    described_class.new(payloads: { 7 => payload(status: "success") })
      .ingest([ run(status: "completed", conclusion: "success") ])

    record = PatchCiRun.find_by(github_run_id: 7)
    expect(record.tests_total).to be_nil
  end

  it "marks a completed run with no payload as infra_error" do
    branch
    described_class.new(payloads: {}).ingest([ run(status: "completed", conclusion: "success") ])

    expect(PatchCiRun.find_by(github_run_id: 7).status).to eq("infra_error")
  end

  it "marks a cancelled run as cancelled" do
    branch
    described_class.new(payloads: {}).ingest([ run(status: "completed", conclusion: "cancelled") ])

    expect(PatchCiRun.find_by(github_run_id: 7).status).to eq("cancelled")
  end

  it "is idempotent" do
    branch
    ingestor = described_class.new(payloads: { 7 => payload })
    2.times { ingestor.ingest([ run(status: "completed", conclusion: "success") ]) }

    expect(PatchCiRun.where(github_run_id: 7).count).to eq(1)
  end

  it "does not promote a superseded run to latest" do
    branch
    described_class.new(payloads: { 9 => payload(run_id: 9) })
      .ingest([ run(status: "completed", conclusion: "success", id: 9, head_sha: "c" * 40) ])

    record = PatchCiRun.find_by(github_run_id: 9)
    expect(record).to be_present
    expect(branch.reload.latest_ci_run_id).to be_nil
    expect(branch.ci_status).to be_nil
  end

  it "records the rejection reason when the payload fails validation" do
    branch
    bad_payload = { schema: 1, branch: "t1_1", run_id: 7, run_attempt: 1, status: "not_a_status" }.to_json
    described_class.new(payloads: { 7 => bad_payload })
      .ingest([ run(status: "completed", conclusion: "success") ])

    record = PatchCiRun.find_by(github_run_id: 7)
    expect(record.status).to eq("infra_error")
    expect(record.payload["ingest_error"]).to match(/unknown status/)
  end

  it "rejects a payload whose run_id does not match the run" do
    branch
    described_class.new(payloads: { 7 => payload(run_id: 999) })
      .ingest([ run(status: "completed", conclusion: "success") ])

    record = PatchCiRun.find_by(github_run_id: 7)
    expect(record.status).to eq("infra_error")
    expect(record.payload["ingest_error"]).to match(/run_id mismatch/)
    expect(record.build_seconds).to be_nil
  end

  it "promotes to the newer run regardless of array order" do
    branch
    described_class.new(payloads: { 7 => payload(status: "success", run_id: 7),
                                     8 => payload(status: "tests_failed", run_id: 8) })
      .ingest([
        run(status: "completed", conclusion: "failure", id: 8),
        run(status: "completed", conclusion: "success", id: 7)
      ])

    newer = PatchCiRun.find_by(github_run_id: 8)
    expect(branch.reload.latest_ci_run_id).to eq(newer.id)
    expect(branch.ci_status).to eq("tests_failed")
  end

  it "does not let a re-ingest with a bad payload erase a recorded verdict" do
    branch
    described_class.new(payloads: { 7 => payload(status: "tests_failed") })
      .ingest([ run(status: "completed", conclusion: "failure") ])

    bad_payload = { schema: 1, branch: "t1_1", run_id: 7, run_attempt: 1, status: "not_a_status" }.to_json
    described_class.new(payloads: { 7 => bad_payload })
      .ingest([ run(status: "completed", conclusion: "failure") ])

    record = PatchCiRun.find_by(github_run_id: 7)
    expect(record.status).to eq("tests_failed")
    expect(record.build_seconds).to eq(100)
    expect(record.failed_tests).to eq([ "regress/foo" ])
    expect(record.image_ref).to eq("ghcr.io/x/postgres-patch:t1")
  end

  it "does not let a re-ingest with a missing payload erase a recorded verdict" do
    branch
    described_class.new(payloads: { 7 => payload(status: "tests_failed") })
      .ingest([ run(status: "completed", conclusion: "failure") ])

    described_class.new(payloads: {}).ingest([ run(status: "completed", conclusion: "failure") ])

    record = PatchCiRun.find_by(github_run_id: 7)
    expect(record.status).to eq("tests_failed")
    expect(record.build_seconds).to eq(100)
  end

  it "records the failure and keeps going when a payload cannot be stored" do
    branch
    calls = 0
    allow_any_instance_of(PatchCiRun).to receive(:save!) do |instance|
      calls += 1
      raise ActiveRecord::StatementInvalid, "test boom" if calls == 1
      instance.save
    end

    described_class.new(payloads: { 7 => payload(status: "success") })
      .ingest([ run(status: "completed", conclusion: "success") ])

    record = PatchCiRun.find_by(github_run_id: 7)
    expect(record).to be_present
    expect(record.status).to eq("infra_error")
    expect(record.payload["ingest_error"]).to match(/unstorable payload/)
  end

  it "returns a status summary of the cycle" do
    branch
    unknown = PatchCi::GithubClient::Run.new(
      id: 99, attempt: 1, branch: "probe_pg20", status: "completed",
      conclusion: "success", head_sha: "z" * 40
    )

    counts = described_class.new(payloads: { 7 => payload(status: "tests_failed") })
      .ingest([ run(status: "completed", conclusion: "failure"), unknown ])

    expect(counts).to eq("tests_failed" => 1, "unknown_branch" => 1)
  end

  it "skips runs for branches it does not know" do
    unknown = PatchCi::GithubClient::Run.new(
      id: 99, attempt: 1, branch: "probe_pg20", status: "completed",
      conclusion: "success", head_sha: "z" * 40
    )

    expect { described_class.new(payloads: {}).ingest([ unknown ]) }
      .not_to change(PatchCiRun, :count)
  end
end
