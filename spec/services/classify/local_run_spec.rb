require "rails_helper"

RSpec.describe Classify::LocalRun do
  let(:result_json) do
    { kind: "feature", size: "minor", enhancement: false, not_a_bug: false, join_linked: [], group: { id: nil, new_name: nil, new_summary: nil },
      feature_name: "x", evidence: [ "e" ], confidence: "high" }.to_json
  end
  let(:topic) do
    t = create(:topic)
    create(:message, topic: t)
    t.reload
  end

  around do |ex|
    Dir.mktmpdir do |dir|
      @dir = dir
      File.write(File.join(dir, "auth.json"), "{}")
      File.write(File.join(dir, "result.src"), result_json)
      fake = File.join(dir, "fake_codex.sh")
      File.write(fake, <<~SH)
        #!/usr/bin/env bash
        out=""
        while [ $# -gt 0 ]; do
          case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
        done
        cat > /dev/null
        echo '{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":10}}'
        cp "#{dir}/result.src" "$out"
      SH
      File.chmod(0o755, fake)
      ex.run
    end
  end

  before do
    Classify::Setup.call!
    create(:release_tag, name: "REL_16_BETA1", released_at: Time.zone.parse("2024-05-21"))
  end

  def run_local(**opts)
    described_class.call(topic:, model: "m", effort: "low", jobs_root: File.join(@dir, "jobs"),
                         codex_bin: File.join(@dir, "fake_codex.sh"), codex_home: File.join(@dir, "home"),
                         auth_path: File.join(@dir, "auth.json"), **opts)
  end

  it "returns result and usage and writes nothing" do
    out = run_local
    expect(out[:result]).to include("kind" => "feature", "size" => "minor")
    expect(out[:usage]).to eq(input_tokens: 100, cached_input_tokens: 40, output_tokens: 10)
    expect(out[:duration_s]).to be_a(Float)
    expect(out[:failure_kind]).to be_nil
    expect(ClassificationRun.count).to eq(0)
    expect(Classify::BotNote.new(topic).note).to be_nil
  end

  it "ingests into a local run" do
    out = run_local(ingest: true)
    expect(out[:failure_kind]).to be_nil
    expect(Classify::BotNote.new(topic).note.body).to eq("@global #feature #minor")
    expect(ClassificationRun.sole).to have_attributes(
      status: "done", worker: "local", phase: "new", model: "m", effort: "low",
      message_count: 1, through_message_id: topic.last_message_id, input_tokens: 100, output_tokens: 10
    )
  end

  it "records a schema failure" do
    File.write(File.join(@dir, "result.src"), "{}")
    out = run_local(ingest: true)
    expect(out[:failure_kind]).to eq("schema")
    expect(ClassificationRun.sole).to have_attributes(status: "failed", failure_kind: "schema")
  end
end
