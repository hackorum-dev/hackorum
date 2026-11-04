require "rails_helper"

RSpec.describe Lineage::Queue do
  def thread(first_at:, n: 2, linked: false, run: nil, merged: false)
    topic = create(:topic, merged_into_topic_id: merged ? create(:topic).id : nil)
    n.times { |i| create(:message, topic: topic, created_at: first_at + i.days, is_patch_submission: true) }
    create(:commit_topic, topic: topic, commit: create(:commit), source: "trailer") if linked
    create(:patchset_run, topic: topic, status: run) if run
    topic
  end

  it "orders phases and topics" do
    old = thread(first_at: Time.zone.parse("2010-01-01"))
    older = thread(first_at: Time.zone.parse("2005-01-01"))
    linked = thread(first_at: Time.zone.parse("2020-01-01"), linked: true)
    recent = thread(first_at: Time.zone.parse("2020-01-01"))
    single_recent = thread(first_at: Time.zone.parse("2021-01-01"), n: 1)
    single_old = thread(first_at: Time.zone.parse("2008-01-01"), n: 1)

    expect(described_class.phase_scope("trailer").to_a).to eq([ linked ])
    expect(described_class.phase_scope("full").to_a).to eq([ old, single_old, older ])
    expect(described_class.phase_scope("lineage").to_a).to eq([ recent ])
    expect(described_class.phase_scope("lineage")).not_to include(single_recent)
    expect(described_class.next).to eq([ linked, "trailer" ])
    expect(described_class.next(phases: %w[lineage full])).to eq([ recent, "lineage" ])
    expect { described_class.phase_scope("nope") }.to raise_error(ArgumentError)
  end

  it "excludes merged topics, topics without patches and topics with a blocking run" do
    thread(first_at: Time.zone.parse("2020-01-01"), merged: true)
    create(:topic).tap { |t| create(:message, topic: t, created_at: Time.zone.parse("2020-01-01")) }
    thread(first_at: Time.zone.parse("2020-01-01"), run: "done")
    thread(first_at: Time.zone.parse("2020-01-01"), run: "failed")
    thread(first_at: Time.zone.parse("2020-01-01"), run: "claimed")
    queued = thread(first_at: Time.zone.parse("2020-01-01"), run: "queued")

    expect(described_class.phase_scope("lineage").to_a).to eq([ queued ])
    expect(described_class.next).to eq([ queued, "lineage" ])
  end

  it "sweeps stale claims so the topic re-queues" do
    topic = thread(first_at: Time.zone.parse("2020-01-01"))
    create(:patchset_run, topic: topic, status: "claimed", claimed_at: 2.hours.ago)
    expect(described_class.next).to be_nil
    expect(described_class.sweep!).to eq(1)
    expect(described_class.next).to eq([ topic, "lineage" ])
  end

  it "counts per phase" do
    thread(first_at: Time.zone.parse("2020-01-01"))
    thread(first_at: Time.zone.parse("2010-01-01"), run: "done").then { |t| PatchsetRun.where(topic: t).update_all(mode: "full") }
    thread(first_at: Time.zone.parse("2019-01-01"), linked: true, run: "claimed").then { |t| PatchsetRun.where(topic: t).update_all(mode: "trailer", claimed_at: Time.current) }

    expect(described_class.counts).to eq(
      "trailer" => { remaining: 0, claimed: 1, done: 0 },
      "full" => { remaining: 0, claimed: 0, done: 1 },
      "lineage" => { remaining: 1, claimed: 0, done: 0 })
  end
end
