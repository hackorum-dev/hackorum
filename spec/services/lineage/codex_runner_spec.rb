require "rails_helper"

RSpec.describe Lineage::CodexRunner do
  let(:fake) { Rails.root.join("spec/fixtures/lineage/fake_codex.sh").to_s }

  def runner(dir, **opts)
    home = File.join(dir, "home")
    auth = File.join(dir, "auth.json")
    File.write(auth, "{}")
    described_class.new(repo_path: "/repo", codex_bin: fake, codex_home: home, auth_path: auth, **opts)
  end

  def with_env(vars)
    old = vars.keys.to_h { |k| [ k, ENV[k] ] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end

  it "runs codex, sums usage, prepares the home" do
    Dir.mktmpdir do |dir|
      job = File.join(dir, "job")
      FileUtils.mkdir_p(job)
      result = runner(dir, model: "m", effort: "low").call(job)

      expect(result.exit_code).to eq(0)
      expect(result.timed_out).to be(false)
      expect(result.failure_kind).to be_nil
      expect(result.error_message).to be_nil
      expect(result.usage).to eq(input_tokens: 150, cached_input_tokens: 40, output_tokens: 15)
      expect(File.read(File.join(job, "result.json"))).to include("fake")
      expect(File.read(File.join(job, "stderr.txt"))).to include("fake stderr")
      expect(File.read(File.join(dir, "home", "config.toml"))).to include("multi_agent")
      expect(File.symlink?(File.join(dir, "home", "auth.json"))).to be(true)
      expect(result.command).to include("-m", "m", "-c", 'model_reasoning_effort="low"', "-s", "workspace-write")
      expect(result.command).not_to include("--add-dir")
    end
  end

  it "times out" do
    Dir.mktmpdir do |dir|
      job = File.join(dir, "job")
      FileUtils.mkdir_p(job)
      result = with_env("FAKE_CODEX_SLEEP" => "30") { runner(dir, timeout: 1).call(job) }
      expect(result.timed_out).to be(true)
      expect(result.failure_kind).to eq("timeout")
    end
  end

  it "reports non-zero exits" do
    Dir.mktmpdir do |dir|
      job = File.join(dir, "job")
      FileUtils.mkdir_p(job)
      result = with_env("FAKE_CODEX_EXIT" => "3") { runner(dir).call(job) }
      expect(result.exit_code).to eq(3)
      expect(result.failure_kind).to eq("codex")
      expect(result.error_message).to be_nil
    end
  end

  {
    "Selected model is at capacity. Please try a different model." => "capacity",
    "You have hit your usage limit." => "usage_limit",
    "something else broke" => "codex"
  }.each do |message, kind|
    it "classifies #{kind} errors" do
      Dir.mktmpdir do |dir|
        job = File.join(dir, "job")
        FileUtils.mkdir_p(job)
        result = with_env("FAKE_CODEX_ERROR" => message) { runner(dir).call(job) }
        expect(result.exit_code).to eq(1)
        expect(result.failure_kind).to eq(kind)
        expect(result.error_message).to eq(message)
      end
    end
  end

  it "fails loudly without an auth file" do
    Dir.mktmpdir do |dir|
      job = File.join(dir, "job")
      FileUtils.mkdir_p(job)
      r = described_class.new(repo_path: "/repo", codex_bin: fake, codex_home: File.join(dir, "home"),
                              auth_path: File.join(dir, "missing.json"))
      expect { r.call(job) }.to raise_error(/auth file missing/)
    end
  end

  it "aborts a running codex" do
    Dir.mktmpdir do |dir|
      job = File.join(dir, "job")
      FileUtils.mkdir_p(job)
      r = runner(dir)
      thread = Thread.new { with_env("FAKE_CODEX_SLEEP" => "30") { r.call(job) } }
      sleep 0.5
      r.abort!
      result = thread.value
      expect(result.aborted).to be(true)
      expect(result.failure_kind).to eq("aborted")
      expect(result.timed_out).to be(false)
    end
  end

  it "does not spawn once aborted" do
    Dir.mktmpdir do |dir|
      job = File.join(dir, "job")
      FileUtils.mkdir_p(job)
      r = runner(dir)
      r.abort!
      result = r.call(job)
      expect(result.aborted).to be(true)
      expect(result.failure_kind).to eq("aborted")
      expect(result.exit_code).to be_nil
      expect(result.usage).to eq(input_tokens: 0, cached_input_tokens: 0, output_tokens: 0)
      expect(File.exist?(File.join(job, "stderr.txt"))).to be(false)
    end
  end

  it "ignores abort with nothing running" do
    Dir.mktmpdir do |dir|
      expect { runner(dir).abort! }.not_to raise_error
    end
  end

  it "reads a stderr tail" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "stderr.txt"), (1..30).map { |i| "line #{i}" }.join("\n"))
      expect(described_class.stderr_tail(dir).lines.size).to eq(20)
      expect(described_class.stderr_tail(File.join(dir, "nope"))).to eq("")
    end
  end
end
