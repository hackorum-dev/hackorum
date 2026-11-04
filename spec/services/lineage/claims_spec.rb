require "rails_helper"

RSpec.describe Lineage::Claims do
  let(:patch) { "diff --git a/src/backend/x.c b/src/backend/x.c\n--- a/src/backend/x.c\n+++ b/src/backend/x.c\n@@ -1,1 +1,2 @@\n a\n+b\n" }

  def patch_message(topic, at)
    m = create(:message, topic: topic, created_at: at, is_patch_submission: true)
    create(:attachment, message: m, file_name: "0001-x.patch", body: Base64.encode64(patch))
    m
  end

  def thread(first_at, linked: false)
    topic = create(:topic)
    patch_message(topic, first_at)
    patch_message(topic, first_at + 1.day)
    create(:commit_topic, topic: topic, commit: create(:commit), source: "trailer") if linked
    topic
  end

  def lineage_result(run)
    { "lineage" => run.bundle_index["patchsets"].each_with_index.map { |p, i|
        { "message_id" => p["message_id"], "parent_message_id" => i.zero? ? nil : run.bundle_index["patchsets"][i - 1]["message_id"],
          "step_kind" => i.zero? ? "new_series" : "resend", "confidence" => 1, "reason" => "r" } },
      "verdicts" => [], "extra_commits" => [], "story" => "s" }
  end

  def result_file(run, data)
    path = File.join(ENV["LINEAGE_BUNDLES_ROOT"], "result-#{run.id}.json")
    File.write(path, JSON.dump(data))
    path
  end

  def bundle_files(id)
    root = ENV["LINEAGE_BUNDLES_ROOT"]
    [ File.join(root, id.to_s), File.join(root, "#{id}.tar.gz") ]
  end

  around do |ex|
    Dir.mktmpdir { |dir| with_env("LINEAGE_BUNDLES_ROOT" => dir) { ex.run } }
  end

  it "claims the next topic with a bundle tarball" do
    linked = thread(Time.zone.parse("2020-01-01"), linked: true)
    run = described_class.claim(worker: "w")

    expect(run.topic).to eq(linked)
    expect(run).to have_attributes(status: "claimed", mode: "trailer", worker: "w", prompt_version: Lineage::JobBundle.prompt_version)
    expect(run.claimed_at).to be_within(5).of(Time.current)
    expect(run.bundle_index["candidates"].size).to eq(1)
    expect(run.bundle_index["patchsets"].size).to eq(2)
    expect(run.through_message_id).to eq(linked.messages.order(:created_at).last.id)
    tar = described_class.bundle_tar(run)
    expect(File.exist?(tar)).to be(true)
    expect(`tar -tzf #{tar}`).to include("index.json", "README.md", "messages/")
    expect(described_class.claim(worker: "w")).to be_nil
  end

  it "rebuilds a missing tarball and refuses finished runs" do
    thread(Time.zone.parse("2020-01-01"))
    run = described_class.claim(worker: "w")
    File.delete(described_class.bundle_tar(run))
    expect(File.exist?(described_class.bundle_tar(run))).to be(true)
    expect(run.reload.bundle_index["patchsets"].size).to eq(2)
    run.update!(status: "done")
    expect { described_class.bundle_tar(run) }.to raise_error(Lineage::Claims::Conflict)
  end

  it "restarts the claim clock when the bundle is downloaded" do
    thread(Time.zone.parse("2020-01-01"))
    run = described_class.claim(worker: "w")
    run.update!(claimed_at: 30.minutes.ago)
    described_class.bundle_tar(run)
    expect(run.reload.claimed_at).to be_within(5).of(Time.current)
  end

  it "ingests a result with the stored index and keeps the given duration" do
    thread(Time.zone.parse("2020-01-01"))
    run = described_class.claim(worker: "w")
    path = result_file(run, lineage_result(run))

    described_class.result!(run, { exit_code: 0, timed_out: false, input_tokens: 10, cached_input_tokens: 2,
                                   output_tokens: 1, duration_s: 42.5, model: "m", effort: "high", job_dir: "/jobs/1" },
                            result_path: path)

    expect(run.reload).to have_attributes(status: "done", mode: "lineage", input_tokens: 10, duration_s: 42.5,
                                          model: "m", effort: "high", job_dir: "/jobs/1")
    expect(run.lineages.count).to eq(2)
    expect(bundle_files(run.id).any? { |f| File.exist?(f) }).to be(false)
    expect { described_class.result!(run, { exit_code: 0 }, result_path: path) }.to raise_error(Lineage::Claims::Conflict)
  end

  it "records failures, timeouts and schema errors" do
    3.times { |i| thread(Time.zone.parse("2020-01-01") + i.days) }
    failed = described_class.claim(worker: "w")
    described_class.result!(failed, { exit_code: 1, failure_kind: "codex", error_message: "boom", stderr_tail: "tail" })
    expect(failed.reload).to have_attributes(status: "failed", failure_kind: "codex")
    expect(failed.error).to eq("codex exit 1: boom\ntail")

    timeout = described_class.claim(worker: "w")
    described_class.result!(timeout, { exit_code: 143, timed_out: true, failure_kind: "timeout" })
    expect(timeout.reload).to have_attributes(status: "timeout", failure_kind: "timeout", error: "killed after timeout")

    schema = described_class.claim(worker: "w")
    path = result_file(schema, "lineage" => [], "verdicts" => [], "extra_commits" => [], "story" => "s")
    described_class.result!(schema, { exit_code: 0 }, result_path: path)
    expect(schema.reload).to have_attributes(status: "failed", failure_kind: "schema")
    expect(schema.error).to include("lineage missing")
  end

  it "fails a clean exit without a result file as an upload error" do
    thread(Time.zone.parse("2020-01-01"))
    run = described_class.claim(worker: "w")
    described_class.result!(run, { exit_code: 0, duration_s: 3.0 })
    expect(run.reload).to have_attributes(status: "failed", failure_kind: "upload", error: "result file missing", duration_s: 3.0)
    expect(bundle_files(run.id).any? { |f| File.exist?(f) }).to be(false)
  end

  it "releases a claim and refuses to release finished runs" do
    topic = thread(Time.zone.parse("2020-01-01"))
    run = described_class.claim(worker: "w")
    described_class.release!(run)
    expect(PatchsetRun.exists?(run.id)).to be(false)
    expect(bundle_files(run.id).any? { |f| File.exist?(f) }).to be(false)
    expect(described_class.claim(worker: "w").topic).to eq(topic)
    done = create(:patchset_run, status: "done")
    expect { described_class.release!(done) }.to raise_error(Lineage::Claims::Conflict)
  end

  it "prunes the files of swept claims" do
    stale = create(:patchset_run, status: "claimed", claimed_at: 2.hours.ago)
    dir, tar = bundle_files(stale.id)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "index.json"), "{}")
    File.write(tar, "x")
    stray = File.join(ENV["LINEAGE_BUNDLES_ROOT"], "notes.txt")
    File.write(stray, "keep")

    expect(described_class.claim(worker: "w")).to be_nil
    expect(PatchsetRun.exists?(stale.id)).to be(false)
    expect(Dir.exist?(dir)).to be(false)
    expect(File.exist?(tar)).to be(false)
    expect(File.exist?(stray)).to be(true)
  end

  it "marks a broken bundle build failed and moves on" do
    broken = thread(Time.zone.parse("2020-01-02"))
    fine = thread(Time.zone.parse("2020-01-01"))
    kaput = instance_double(Lineage::BundleWriter)
    allow(kaput).to receive(:call).and_raise("kaput")
    allow(Lineage::BundleWriter).to receive(:new).and_wrap_original do |m, **kw|
      kw[:topic] == broken ? kaput : m.call(**kw)
    end

    run = described_class.claim(worker: "w")
    expect(run.topic).to eq(fine)
    expect(PatchsetRun.find_by(topic: broken)).to have_attributes(status: "failed", failure_kind: "bundle")
    expect(PatchsetRun.find_by(topic: broken).error).to include("kaput")
    expect(bundle_files(PatchsetRun.find_by(topic: broken).id).any? { |f| File.exist?(f) }).to be(false)
  end

  it "gives up after five broken builds in a row" do
    5.times { |i| thread(Time.zone.parse("2020-01-01") + i.days) }
    allow(Lineage::BundleWriter).to receive(:new).and_raise("kaput")

    expect { described_class.claim(worker: "w") }.to raise_error(Lineage::Claims::Error, /5 bundle builds/)
    expect(PatchsetRun.where(status: "failed", failure_kind: "bundle").count).to eq(5)
    expect(PatchsetRun.claimed.count).to eq(0)
  end
end
