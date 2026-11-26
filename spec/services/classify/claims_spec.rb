require "rails_helper"

RSpec.describe Classify::Claims do
  let(:now) { Time.zone.parse("2026-11-26 12:00") }
  let(:hackers) { create(:mailing_list, identifier: "pgsql-hackers") }

  before do
    Classify::Setup.call!
    travel_to(now)
    create(:release_tag, name: "REL_16_BETA1", released_at: Time.zone.parse("2024-05-21"))
  end

  after { travel_back }

  around do |ex|
    Dir.mktmpdir { |dir| with_env("CLASSIFY_BUNDLES_ROOT" => dir) { ex.run } }
  end

  def thread(first_at: 3.days.ago, n: 2)
    topic = create(:topic, created_at: first_at)
    n.times { |i| create(:message, topic:, created_at: first_at + i.minutes) }
    create(:topic_mailing_list, topic:, mailing_list: hackers)
    topic.reload
  end

  def result_file(data = nil)
    data ||= { kind: "feature", size: "minor", enhancement: false, not_a_bug: false, join_linked: [], group: { id: nil, new_name: nil, new_summary: nil },
               feature_name: "x", evidence: [ "e" ], confidence: "high" }
    path = File.join(ENV["CLASSIFY_BUNDLES_ROOT"], "result.json")
    File.write(path, JSON.dump(data))
    path
  end

  it "claims the next topic with counts and returns nil when empty" do
    topic = thread
    run = described_class.claim(worker: "w", phases: %w[new backfill])
    expect(run).to have_attributes(topic_id: topic.id, status: "claimed", phase: "new", worker: "w",
                                   message_count: 2, through_message_id: topic.last_message_id,
                                   prompt_version: Classify::BundleWriter.prompt_version)
    expect(run.claimed_at).to be_present
    expect(described_class.claim(worker: "w")).to be_nil
  end

  it "refuses to claim before setup ran" do
    thread
    GlobalTag.find_by!(name: "minor").retire!
    expect { described_class.claim(worker: "w") }.to raise_error(described_class::NotReady, /setup/)
    GlobalTag.find_by!(name: "minor").unretire!
    GlobalTag.where(name: "not-a-bug").delete_all
    expect { described_class.claim(worker: "w") }.to raise_error(described_class::NotReady)
    Classify::Setup.call!
    Classify.bot_user.update_column(:username, "someone")
    expect { described_class.claim(worker: "w") }.to raise_error(described_class::NotReady)
    expect(ClassificationRun.count).to eq(0)
  end

  it "sweeps stale claims before claiming" do
    topic = thread
    stale = create(:classification_run, topic:, status: "claimed", claimed_at: 2.hours.ago, finished_at: nil)
    run = described_class.claim(worker: "w")
    expect(ClassificationRun.exists?(stale.id)).to be(false)
    expect(run.topic_id).to eq(topic.id)
  end

  it "builds the bundle and refreshes counts from its index" do
    topic = thread
    run = described_class.claim(worker: "w")
    create(:message, topic:, created_at: Time.current)
    path = described_class.bundle_tar(run)
    expect(`tar -tzf #{path}`).to include("prompt.md")
    expect(run.reload.message_count).to eq(3)
  end

  it "fails the run and conflicts when the bundle build breaks" do
    thread
    run = described_class.claim(worker: "w")
    allow_any_instance_of(Classify::BundleWriter).to receive(:write) do |_, dir|
      FileUtils.mkdir_p(File.join(dir, "messages"))
      raise "disk full"
    end
    expect { described_class.bundle_tar(run) }.to raise_error(described_class::Conflict, /disk full/)
    expect(run.reload).to have_attributes(status: "failed", failure_kind: "bundle")
    expect(run.error).to include("RuntimeError: disk full")
    expect(Dir.children(ENV["CLASSIFY_BUNDLES_ROOT"])).to be_empty
    expect { described_class.bundle_tar(run) }.to raise_error(described_class::Conflict)
  end

  it "stores model and tokens in every outcome" do
    thread
    run = described_class.claim(worker: "w")
    described_class.result!(run, { exit_code: 1, model: "m", effort: "low", input_tokens: 5, output_tokens: 2, error_message: "boom" })
    expect(run.reload).to have_attributes(status: "failed", model: "m", effort: "low", input_tokens: 5, output_tokens: 2)
    expect(run.error).to include("codex exit 1: boom")
  end

  it "stores the failure kind the processor reported" do
    thread
    run = described_class.claim(worker: "w")
    described_class.result!(run, { exit_code: -1, failure_kind: "processor", error_message: "kaput" })
    expect(run.reload).to have_attributes(status: "failed", failure_kind: "processor")
  end

  it "records timeouts" do
    thread
    run = described_class.claim(worker: "w")
    described_class.result!(run, { timed_out: true, model: "m" })
    expect(run.reload).to have_attributes(status: "timeout", model: "m")
  end

  it "fails uploads without a file" do
    thread
    run = described_class.claim(worker: "w")
    described_class.result!(run, { exit_code: 0 })
    expect(run.reload).to have_attributes(status: "failed", failure_kind: "upload")
  end

  it "marks schema errors" do
    thread
    run = described_class.claim(worker: "w")
    described_class.result!(run, { exit_code: 0 }, result_path: result_file({ kind: "nope" }))
    expect(run.reload).to have_attributes(status: "failed", failure_kind: "schema")
  end

  it "rolls back and marks ingest errors" do
    thread
    run = described_class.claim(worker: "w")
    allow_any_instance_of(Classify::BotNote).to receive(:write!).and_raise("x")
    described_class.result!(run, { exit_code: 0, model: "m" }, result_path: result_file)
    expect(run.reload).to have_attributes(status: "failed", failure_kind: "ingest", model: "m")
  end

  it "ingests a good result and refuses a second one" do
    thread
    run = described_class.claim(worker: "w")
    described_class.result!(run, { exit_code: 0 }, result_path: result_file)
    expect(run.reload).to have_attributes(status: "done", kind: "feature")
    expect { described_class.result!(run, { exit_code: 0 }, result_path: result_file) }.to raise_error(described_class::Conflict)
  end

  it "deletes the run and conflicts when the topic was merged away" do
    topic = thread
    run = described_class.claim(worker: "w")
    topic.update!(merged_into_topic: create(:topic))
    expect { described_class.result!(run, { exit_code: 0 }, result_path: result_file) }.to raise_error(described_class::Conflict)
    expect(ClassificationRun.exists?(run.id)).to be(false)
  end

  it "releases a claim" do
    thread
    run = described_class.claim(worker: "w")
    described_class.release!(run)
    expect(ClassificationRun.exists?(run.id)).to be(false)
  end
end
