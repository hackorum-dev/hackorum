require "rails_helper"

RSpec.describe Lineage::TopicJob do
  JOB_PATCH = "diff --git a/src/backend/x.c b/src/backend/x.c\n--- a/src/backend/x.c\n+++ b/src/backend/x.c\n@@ -1,1 +1,2 @@\n a\n+b\n"

  def patch_message(topic, at)
    m = create(:message, topic: topic, created_at: at, is_patch_submission: true)
    create(:attachment, message: m, file_name: "0001-x.patch", body: Base64.encode64(JOB_PATCH))
    m
  end

  let(:topic) { create(:topic) }
  let!(:m1) { patch_message(topic, 2.days.ago) }
  let!(:m2) { patch_message(topic, 1.day.ago) }

  def job(dir, runner:, candidates: [], **opts)
    described_class.new(topic: topic, candidates: candidates, repo_path: dir, jobs_root: File.join(dir, "jobs"),
                        worktrees_dir: File.join(dir, "wt"), apply: false, runner: runner, **opts)
  end

  def fake_runner(&block)
    runner = instance_double(Lineage::CodexRunner, model: "fake")
    allow(runner).to receive(:call, &block)
    runner
  end

  def good_result
    Lineage::CodexRunner::Result.new(exit_code: 0, timed_out: false,
                                     usage: { input_tokens: 1, cached_input_tokens: 0, output_tokens: 1 }, command: [])
  end

  it "runs end to end with a fake runner" do
    Dir.mktmpdir do |dir|
      runner = fake_runner do |job_dir|
        File.write(File.join(job_dir, "result.json"), JSON.dump(
          "lineage" => [ { "message_id" => m1.id, "parent_message_id" => nil, "step_kind" => "new_series", "confidence" => 1, "reason" => "r" },
                         { "message_id" => m2.id, "parent_message_id" => m1.id, "step_kind" => "resend", "confidence" => 1, "reason" => "r" } ],
          "verdicts" => [], "story" => "s"))
        good_result
      end

      run = job(dir, runner: runner).call
      expect(run.status).to eq("done")
      expect(run.model).to eq("fake")
      expect(run.lineages.count).to eq(2)
      expect(run.input_tokens).to eq(1)
      expect(run.mode).to eq("full")
      expect(run.through_message_id).to eq(m2.id)
      expect(PatchsetPair.where(topic_id: topic.id).count).to eq(1)
      expect(File.exist?(File.join(run.job_dir, "index.json"))).to be(true)
      expect(File.exist?(File.join(run.job_dir, "commit_scores.json"))).to be(true)
    end
  end

  it "runs in the given mode" do
    Dir.mktmpdir do |dir|
      runner = fake_runner { |_| good_result }
      run = job(dir, runner: runner, mode: "lineage", dry_run: true).call
      expect(run.mode).to eq("lineage")
      expect(File.read(File.join(run.job_dir, "README.md"))).to include("must be `[]`")
    end
  end

  it "adds currently llm-linked commits as candidates" do
    Dir.mktmpdir do |dir|
      linked = create(:commit)
      create(:commit_topic, topic: topic, commit: linked, source: "llm", confidence: 0.9)
      runner = fake_runner { |_| good_result }
      run = job(dir, runner: runner, dry_run: true).call
      index = JSON.parse(File.read(File.join(run.job_dir, "index.json")))
      expect(index["candidates"].map { |c| [ c["sha"], c["origin"] ] }).to eq([ [ linked.sha, "previous" ] ])
    end
  end

  it "folds backports into their canonical candidate" do
    Dir.mktmpdir do |dir|
      canonical = create(:commit)
      backport = create(:commit, cherry_picked_from_sha: canonical.sha, branches: [ "REL_17_STABLE" ])
      create(:commit_person, commit: canonical, role: "reviewer", raw_name: "Alice")
      create(:commit_person, commit: backport, role: "reviewer", raw_name: "Alice")
      person = create(:person)
      create(:alias, person: person, name: "Bob B")
      create(:commit_person, commit: backport, role: "reviewer", raw_name: "", person: person)
      create(:commit_person, commit: canonical, role: "author", raw_name: "Carol")
      cands = [ { commit: backport, origin: "trailer", overlap: nil }, { commit: canonical, origin: "trailer", overlap: nil } ]
      runner = fake_runner { |_| good_result }
      run = job(dir, runner: runner, candidates: cands, dry_run: true).call
      index = JSON.parse(File.read(File.join(run.job_dir, "index.json")))
      expect(index["mode"]).to eq("trailer")
      expect(index["candidates"]).to contain_exactly(
        a_hash_including("sha" => canonical.sha, "origin" => "trailer", "backports" => [ backport.sha ],
                         "reviewers" => [ "Alice", "Bob B" ]))
      expect(File.exist?(File.join(run.job_dir, "README.md"))).to be(true)
    end
  end

  it "folds two backports of one canonical and lifts a trailer origin onto it" do
    Dir.mktmpdir do |dir|
      canonical = create(:commit)
      b17 = create(:commit, cherry_picked_from_sha: canonical.sha, branches: [ "REL_17_STABLE" ])
      b16 = create(:commit, cherry_picked_from_sha: canonical.sha, branches: [ "REL_16_STABLE" ])
      cands = [ { commit: canonical, origin: "previous", overlap: nil },
                { commit: b17, origin: "trailer", overlap: nil },
                { commit: b16, origin: "trailer", overlap: nil } ]
      runner = fake_runner { |_| good_result }
      run = job(dir, runner: runner, candidates: cands, dry_run: true).call
      index = JSON.parse(File.read(File.join(run.job_dir, "index.json")))
      expect(index["mode"]).to eq("trailer")
      expect(index["candidates"].size).to eq(1)
      expect(index["candidates"].first).to include("sha" => canonical.sha, "origin" => "trailer")
      expect(index["candidates"].first["backports"]).to contain_exactly(b17.sha, b16.sha)
    end
  end

  it "stays in trailer mode with a manual candidate alongside, keeping its origin" do
    Dir.mktmpdir do |dir|
      trailer = create(:commit)
      manual = create(:commit)
      cands = [ { commit: trailer, origin: "trailer", overlap: nil }, { commit: manual, origin: "manual", overlap: nil } ]
      runner = fake_runner { |_| good_result }
      run = job(dir, runner: runner, candidates: cands, dry_run: true).call
      index = JSON.parse(File.read(File.join(run.job_dir, "index.json")))
      expect(index["mode"]).to eq("trailer")
      expect(index["candidates"].map { |c| [ c["sha"], c["origin"] ] })
        .to contain_exactly([ trailer.sha, "trailer" ], [ manual.sha, "manual" ])
    end
  end

  it "keeps a lone backport as its own candidate" do
    Dir.mktmpdir do |dir|
      backport = create(:commit, cherry_picked_from_sha: "f" * 40, branches: [ "REL_17_STABLE" ])
      runner = fake_runner { |_| good_result }
      run = job(dir, runner: runner, candidates: [ { commit: backport, origin: "manual", overlap: nil } ], dry_run: true).call
      index = JSON.parse(File.read(File.join(run.job_dir, "index.json")))
      expect(index["mode"]).to eq("full")
      expect(index["candidates"]).to contain_exactly(
        a_hash_including("sha" => backport.sha, "origin" => "manual", "backports" => [], "reviewers" => []))
    end
  end

  it "hands the ingestor the candidate index with origin, backports and reviewers" do
    Dir.mktmpdir do |dir|
      canonical = create(:commit)
      backport = create(:commit, cherry_picked_from_sha: canonical.sha, branches: [ "REL_17_STABLE" ])
      create(:commit_person, commit: canonical, role: "reviewer", raw_name: "Alice")
      create(:commit_person, commit: canonical, role: "reviewer", raw_name: "Guessed", source: "llm", confidence: 0.9)
      seen = nil
      allow(Lineage::ResultIngestor).to receive(:new).and_wrap_original do |m, **kw|
        seen = kw[:index]
        m.call(**kw)
      end
      runner = fake_runner do |job_dir|
        File.write(File.join(job_dir, "result.json"), JSON.dump("lineage" => [], "verdicts" => [], "story" => "s"))
        good_result
      end
      job(dir, runner: runner, candidates: [ { commit: canonical, origin: "trailer", overlap: nil },
                                             { commit: backport, origin: "previous", overlap: nil } ]).call
      expect(seen["patchsets"]).to eq([ { "message_id" => m1.id }, { "message_id" => m2.id } ])
      expect(seen["candidates"]).to eq([ { "sha" => canonical.sha, "origin" => "trailer",
                                           "backports" => [ backport.sha ], "reviewers" => [ "Alice" ],
                                           "committer_reviewers" => [] } ])
    end
  end

  it "records a timeout" do
    Dir.mktmpdir do |dir|
      runner = fake_runner do |_|
        Lineage::CodexRunner::Result.new(exit_code: nil, timed_out: true, failure_kind: "timeout",
                                         usage: { input_tokens: 0, cached_input_tokens: 0, output_tokens: 0 }, command: [])
      end
      run = job(dir, runner: runner).call
      expect(run.status).to eq("timeout")
      expect(run.failure_kind).to eq("timeout")
    end
  end

  it "records a non-zero exit with the stderr tail" do
    Dir.mktmpdir do |dir|
      runner = fake_runner do |job_dir|
        File.write(File.join(job_dir, "stderr.txt"), "boom\n")
        Lineage::CodexRunner::Result.new(exit_code: 2, timed_out: false, failure_kind: "codex",
                                         usage: { input_tokens: 0, cached_input_tokens: 0, output_tokens: 0 }, command: [])
      end
      run = job(dir, runner: runner).call
      expect(run.status).to eq("failed")
      expect(run.failure_kind).to eq("codex")
      expect(run.error).to start_with("codex exit 2\n").and include("boom")
    end
  end

  it "leads the error text with the codex message" do
    Dir.mktmpdir do |dir|
      runner = fake_runner do |_|
        Lineage::CodexRunner::Result.new(exit_code: 1, timed_out: false, failure_kind: "capacity",
                                         error_message: "Selected model is at capacity.",
                                         usage: { input_tokens: 0, cached_input_tokens: 0, output_tokens: 0 }, command: [])
      end
      run = job(dir, runner: runner).call
      expect(run.status).to eq("failed")
      expect(run.failure_kind).to eq("capacity")
      expect(run.error).to start_with("codex exit 1: Selected model is at capacity.")
    end
  end

  it "marks the run failed when the runner raises" do
    Dir.mktmpdir do |dir|
      runner = fake_runner { |_| raise "boom" }
      run = job(dir, runner: runner).call
      expect(run.status).to eq("failed")
      expect(run.error).to include("RuntimeError: boom")
      expect(File.exist?(File.join(run.job_dir, "index.json"))).to be(true)
    end
  end

  it "marks the run failed when the answer is invalid" do
    Dir.mktmpdir do |dir|
      runner = fake_runner do |job_dir|
        File.write(File.join(job_dir, "result.json"), JSON.dump("lineage" => [], "verdicts" => [], "story" => "s"))
        good_result
      end
      run = job(dir, runner: runner).call
      expect(run.status).to eq("failed")
      expect(run.failure_kind).to eq("schema")
      expect(run.error).to include("lineage missing")
    end
  end

  it "stops after the bundle in dry run" do
    Dir.mktmpdir do |dir|
      runner = instance_double(Lineage::CodexRunner, model: "fake")
      expect(runner).not_to receive(:call)
      run = job(dir, runner: runner, dry_run: true).call
      expect(run.status).to eq("queued")
      expect(File.exist?(File.join(run.job_dir, "README.md"))).to be(true)
    end
  end
end
