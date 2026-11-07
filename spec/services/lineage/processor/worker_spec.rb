require "rails_helper"

RSpec.describe Lineage::Processor::Worker do
  def result(exit_code: 0, failure_kind: nil, timed_out: false, aborted: false, error: nil)
    Lineage::CodexRunner::Result.new(exit_code: exit_code, timed_out: timed_out, aborted: aborted, command: [],
                                     failure_kind: failure_kind, error_message: error,
                                     usage: { input_tokens: 3, cached_input_tokens: 1, output_tokens: 2 })
  end

  def tarball(dir)
    src = File.join(dir, "src")
    FileUtils.mkdir_p(src)
    File.write(File.join(src, "index.json"), "{}")
    File.write(File.join(src, "README.md"), "{{repo_path}}")
    tar = File.join(dir, "b.tar.gz")
    system("tar", "-czf", tar, "-C", src, ".", exception: true)
    tar
  end

  let(:claim) { Lineage::Processor::Client::Claim.new(run_id: 7, topic_id: 3, mode: "lineage", prompt_version: "p") }
  let(:stop) { Lineage::Processor::StopFlag.new }
  let(:completer) { instance_double(Lineage::BundleCompleter, call: {}) }
  let(:lines) { [] }

  def client(dir, submit: { "status" => "done", "error" => nil })
    c = instance_double(Lineage::Processor::Client)
    allow(c).to receive(:claim).and_return(claim)
    allow(c).to receive(:download_bundle) { |_, to:| FileUtils.cp(tarball(dir), to); to }
    allow(c).to receive(:submit_result).and_return(submit)
    allow(c).to receive(:release)
    c
  end

  def runner(*results)
    r = instance_double(Lineage::CodexRunner, model: "m", effort: "high")
    allow(r).to receive(:call) do |job_dir|
      res = results.shift
      File.write(File.join(job_dir, "result.json"), '{"story":"s"}') if res.exit_code == 0
      res
    end
    r
  end

  def worker(dir, client:, runner:, **opts)
    described_class.new(client: client, runner: runner, completer: completer, jobs_root: File.join(dir, "jobs"),
                        worker_name: "w", phases: nil, stop: stop, say: ->(l) { lines << l },
                        capacity_sleeps: [ 0, 0, 0 ], server_sleeps: [ 0, 0 ], release_sleeps: [ 0 ], bundle_poll: 0, **opts)
  end

  it "runs a claim end to end" do
    Dir.mktmpdir do |dir|
      c = client(dir)
      out = worker(dir, client: c, runner: runner(result)).run_one
      expect(out.kind).to eq(:done)
      expect(out.status).to eq("done")
      job_dir = File.join(dir, "jobs", "3", "7")
      expect(File.exist?(File.join(job_dir, "README.md"))).to be(true)
      expect(File.exist?(File.join(job_dir, "uploaded"))).to be(true)
      expect(completer).to have_received(:call).with(job_dir)
      expect(c).to have_received(:submit_result).with(7, hash_including(exit_code: 0, timed_out: false, model: "m",
        effort: "high", job_dir: job_dir, input_tokens: 3, cached_input_tokens: 1, output_tokens: 2), result_path: File.join(job_dir, "result.json"))
      expect(c).not_to have_received(:release)
    end
  end

  it "returns empty without a claim" do
    Dir.mktmpdir do |dir|
      c = client(dir)
      allow(c).to receive(:claim).and_return(nil)
      expect(worker(dir, client: c, runner: runner).run_one.kind).to eq(:empty)
    end
  end

  it "retries capacity errors on the schedule, then stops" do
    Dir.mktmpdir do |dir|
      c = client(dir)
      cap = result(exit_code: 1, failure_kind: "capacity", error: "at capacity")
      out = worker(dir, client: c, runner: runner(cap, cap, cap, result)).run_one
      expect(out.kind).to eq(:done)
      expect(stop.set?).to be(false)

      r = runner(cap, cap, cap, cap)
      out = worker(dir, client: c, runner: r).run_one
      expect(out.kind).to eq(:stopped)
      expect(out.status).to eq("capacity")
      expect(r).to have_received(:call).exactly(4).times
      expect(stop.set?).to be(true)
      expect(c).to have_received(:release).with(7)
    end
  end

  %w[usage_limit aborted].each do |kind|
    it "stops and releases on #{kind}" do
      Dir.mktmpdir do |dir|
        c = client(dir)
        res = result(exit_code: 1, failure_kind: kind, aborted: kind == "aborted", error: "boom")
        out = worker(dir, client: c, runner: runner(res)).run_one
        expect(out.kind).to eq(:stopped)
        expect(out.status).to eq(kind)
        expect(stop.set?).to be(true)
        expect(c).to have_received(:release).with(7)
        expect(c).not_to have_received(:submit_result)
      end
    end
  end

  it "stops and releases when the checkout lacks a candidate" do
    Dir.mktmpdir do |dir|
      c = client(dir)
      allow(completer).to receive(:call).and_raise(Lineage::BundleCompleter::MissingCommits, "abc not in repo after fetch")
      r = runner
      out = worker(dir, client: c, runner: r).run_one
      expect(out.kind).to eq(:stopped)
      expect(out.status).to eq("stale_repo")
      expect(stop.set?).to be(true)
      expect(c).to have_received(:release).with(7)
      expect(c).not_to have_received(:submit_result)
      expect(r).not_to have_received(:call)
    end
  end

  it "stops without running codex when the stop flag is set while completing the bundle" do
    Dir.mktmpdir do |dir|
      c = client(dir)
      allow(completer).to receive(:call) { stop.set! }
      r = runner
      out = worker(dir, client: c, runner: r).run_one
      expect(out.kind).to eq(:stopped)
      expect(out.status).to eq("aborted")
      expect(c).to have_received(:release).with(7)
      expect(c).not_to have_received(:submit_result)
      expect(r).not_to have_received(:call)
    end
  end

  it "stops without rerunning codex when the stop flag is set during the capacity backoff" do
    Dir.mktmpdir do |dir|
      c = client(dir)
      cap = result(exit_code: 1, failure_kind: "capacity", error: "at capacity")
      r = runner(cap, result)
      w = worker(dir, client: c, runner: r, capacity_sleeps: [ 60 ])
      allow(w).to receive(:sleep) { stop.set! }
      out = w.run_one
      expect(out.kind).to eq(:stopped)
      expect(out.status).to eq("aborted")
      expect(c).to have_received(:release).with(7)
      expect(r).to have_received(:call).once
    end
  end

  it "uploads a processor failure when completing the bundle fails" do
    Dir.mktmpdir do |dir|
      c = client(dir)
      allow(completer).to receive(:call).and_raise(PatchBranches::GitRepo::Error, "no such sha")
      out = worker(dir, client: c, runner: runner).run_one
      expect(out.kind).to eq(:done)
      expect(c).to have_received(:submit_result).with(7, hash_including(exit_code: -1, failure_kind: "processor",
        error_message: a_string_including("no such sha")), result_path: nil)
    end
  end

  it "stops once the upload retries run out" do
    Dir.mktmpdir do |dir|
      c = client(dir)
      allow(c).to receive(:submit_result).and_raise(Lineage::Processor::Client::Error, "down")
      out = worker(dir, client: c, runner: runner(result)).run_one
      expect(out.kind).to eq(:stopped)
      expect(c).to have_received(:submit_result).exactly(3).times
      expect(c).to have_received(:release).with(7)
      expect(stop.set?).to be(true)
    end
  end

  it "gives up an upload retry when stopped" do
    Dir.mktmpdir do |dir|
      c = client(dir)
      allow(c).to receive(:submit_result).and_raise(Lineage::Processor::Client::Error, "down")
      w = worker(dir, client: c, runner: runner(result), server_sleeps: [ 60, 60 ])
      allow(w).to receive(:sleep) { stop.set! }
      expect(w.run_one.kind).to eq(:stopped)
      expect(c).to have_received(:submit_result).once
      expect(c).to have_received(:release).with(7)
    end
  end

  it "retries a failed upload" do
    Dir.mktmpdir do |dir|
      c = client(dir)
      calls = 0
      allow(c).to receive(:submit_result) { calls += 1; raise Lineage::Processor::Client::Error, "down" if calls == 1; { "status" => "done" } }
      out = worker(dir, client: c, runner: runner(result)).run_one
      expect(out.kind).to eq(:done)
      expect(calls).to eq(2)
      expect(stop.set?).to be(false)
    end
  end

  it "reports a refused upload without stopping or marking the job uploaded" do
    Dir.mktmpdir do |dir|
      c = client(dir)
      allow(c).to receive(:submit_result).and_raise(Lineage::Processor::Client::Conflict, "404: swept")
      out = worker(dir, client: c, runner: runner(result)).run_one
      expect(out.kind).to eq(:refused)
      expect(out.error).to eq("404: swept")
      expect(File.exist?(File.join(dir, "jobs", "3", "7", "uploaded"))).to be(false)
      expect(stop.set?).to be(false)
      expect(lines).to include(a_string_including("refused"))
      expect(c).not_to have_received(:release)
    end
  end

  describe "consecutive failures" do
    def failing_client(dir)
      c = client(dir)
      allow(c).to receive(:submit_result) { |_, fields, **| { "status" => fields[:failure_kind] ? "failed" : "done" } }
      c
    end

    it "stops after three processor failures in a row" do
      Dir.mktmpdir do |dir|
        c = failing_client(dir)
        allow(completer).to receive(:call).and_raise("kaput")
        w = worker(dir, client: c, runner: runner)
        expect(w.run_one.kind).to eq(:done)
        expect(w.run_one.kind).to eq(:done)
        out = w.run_one
        expect(out.kind).to eq(:stopped)
        expect(out.status).to eq("failed")
        expect(stop.set?).to be(true)
        expect(lines).to include(a_string_including("3 processor failures in a row"))
        expect(c).to have_received(:submit_result).exactly(3).times
        expect(c).not_to have_received(:release)
      end
    end

    it "resets the count on a success" do
      Dir.mktmpdir do |dir|
        c = failing_client(dir)
        calls = 0
        allow(completer).to receive(:call) { calls += 1; raise "kaput" if calls <= 2; {} }
        w = worker(dir, client: c, runner: runner(result, result))
        4.times { expect(w.run_one.kind).to eq(:done) }
        expect(stop.set?).to be(false)
      end
    end

    it "honours a custom limit" do
      Dir.mktmpdir do |dir|
        c = failing_client(dir)
        allow(completer).to receive(:call).and_raise("kaput")
        w = worker(dir, client: c, runner: runner, max_failures: 1)
        expect(w.run_one.kind).to eq(:stopped)
      end
    end
  end

  it "stops once claim retries run out" do
    Dir.mktmpdir do |dir|
      c = client(dir)
      allow(c).to receive(:claim).and_raise(Lineage::Processor::Client::Error, "ECONNREFUSED")
      out = worker(dir, client: c, runner: runner).run_one
      expect(out.kind).to eq(:stopped)
      expect(c).to have_received(:claim).exactly(3).times
      expect(stop.set?).to be(true)
      expect(c).not_to have_received(:release)
    end
  end

  it "retries a failed claim and download" do
    Dir.mktmpdir do |dir|
      c = client(dir)
      claims = downloads = 0
      allow(c).to receive(:claim) { claims += 1; raise Lineage::Processor::Client::Error, "502" if claims == 1; claim }
      allow(c).to receive(:download_bundle) do |_, to:|
        downloads += 1
        raise Lineage::Processor::Client::Error, "502" if downloads == 1
        FileUtils.cp(tarball(dir), to)
        to
      end
      out = worker(dir, client: c, runner: runner(result)).run_one
      expect(out.kind).to eq(:done)
      expect([ claims, downloads ]).to eq([ 2, 2 ])
      expect(lines).to include(a_string_including("claim failed (502), retrying"))
    end
  end

  it "retries the release after a stop, then leaves it to the sweep" do
    Dir.mktmpdir do |dir|
      c = client(dir)
      allow(c).to receive(:download_bundle).and_raise(Lineage::Processor::Client::Error, "502")
      allow(c).to receive(:release).and_raise(Lineage::Processor::Client::Error, "502")
      out = worker(dir, client: c, runner: runner).run_one
      expect(out.kind).to eq(:stopped)
      expect(c).to have_received(:download_bundle).exactly(3).times
      expect(c).to have_received(:release).with(7).twice
      expect(lines).to include(a_string_including("left for the server sweep"))
    end
  end

  it "polls until the bundle is built" do
    Dir.mktmpdir do |dir|
      c = client(dir)
      polls = 0
      allow(c).to receive(:download_bundle) do |_, to:|
        polls += 1
        next nil if polls < 3
        FileUtils.cp(tarball(dir), to)
        to
      end
      out = worker(dir, client: c, runner: runner(result)).run_one
      expect(out.kind).to eq(:done)
      expect(polls).to eq(3)
    end
  end

  it "releases the claim when stopped while the bundle builds" do
    Dir.mktmpdir do |dir|
      c = client(dir)
      allow(c).to receive(:download_bundle) { stop.set!; nil }
      r = runner
      out = worker(dir, client: c, runner: r).run_one
      expect(out).to have_attributes(kind: :stopped, status: "aborted")
      expect(c).to have_received(:release).with(7)
      expect(r).not_to have_received(:call)
    end
  end

  it "gives up a bundle that never gets built" do
    Dir.mktmpdir do |dir|
      c = client(dir)
      allow(c).to receive(:download_bundle).and_return(nil)
      out = worker(dir, client: c, runner: runner, bundle_wait: 0).run_one
      expect(out.kind).to eq(:stopped)
      expect(out.error).to include("not ready after 0s")
      expect(c).to have_received(:release).with(7)
    end
  end

  it "moves past refused bundles, stopping after three in a row" do
    Dir.mktmpdir do |dir|
      c = client(dir)
      allow(c).to receive(:download_bundle).and_raise(Lineage::Processor::Client::Conflict, "409: bundle failed: kaput")
      w = worker(dir, client: c, runner: runner)
      2.times { expect(w.run_one).to have_attributes(kind: :refused, error: a_string_including("kaput")) }
      expect(stop.set?).to be(false)
      expect(w.run_one.kind).to eq(:stopped)
      expect(stop.set?).to be(true)
      expect(c).not_to have_received(:release)
      expect(lines).to include(a_string_including("3 bundles refused in a row"))
    end
  end
end
