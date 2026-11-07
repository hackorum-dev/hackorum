require "rails_helper"

RSpec.describe Lineage::Queue do
  def thread(first_at:, n: 2, linked: false, run: nil, merged: false)
    topic = create(:topic, merged_into_topic_id: merged ? create(:topic).id : nil)
    last = nil
    n.times { |i| last = create(:message, topic: topic, created_at: first_at + i.days, is_patch_submission: true) }
    create(:commit_topic, topic: topic, commit: create(:commit), source: "trailer") if linked
    create(:patchset_run, topic: topic, status: run, through_message: last) if run
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
      "update" => { remaining: 0, claimed: 0, done: 0 },
      "discussion" => { remaining: 0, claimed: 0, done: 0 },
      "full" => { remaining: 0, claimed: 0, done: 1 },
      "lineage" => { remaining: 1, claimed: 0, done: 0 })
  end

  describe "discussion" do
    def discussion_topic(run: nil)
      topic = create(:topic)
      create(:message, topic: topic, created_at: 2.days.ago)
      create(:commit_topic, topic: topic, commit: create(:commit), source: "trailer")
      create(:patchset_run, topic: topic, status: run) if run
      topic
    end

    it "takes trailer-linked topics without patch mail and without a run" do
      wanted = discussion_topic
      discussion_topic(run: "done")
      discussion_topic(run: "claimed")
      thread(first_at: Time.zone.parse("2020-01-01"), linked: true)
      create(:topic).tap { |t| create(:message, topic: t) }

      expect(described_class.phase_scope("discussion").to_a).to eq([ wanted ])
    end

    it "leaves out llm-only and merged topics" do
      llm = create(:topic)
      create(:message, topic: llm, created_at: 2.days.ago)
      create(:commit_topic, topic: llm, commit: create(:commit), source: "llm", confidence: 0.9)
      merged = discussion_topic
      merged.update!(merged_into_topic_id: create(:topic).id)

      expect(described_class.phase_scope("discussion").to_a).to eq([])
    end

    it "orders trailer, update, discussion" do
      linked = thread(first_at: Time.zone.parse("2020-01-01"), linked: true)
      discussion = discussion_topic
      upd = create(:topic)
      v1 = create(:message, topic: upd, created_at: 3.days.ago, is_patch_submission: true)
      create(:patchset_run, topic: upd, status: "done", mode: "trailer", through_message: v1, created_at: 2.days.ago)
      create(:commit_topic, topic: upd, commit: create(:commit), source: "trailer")

      expect(described_class.next).to eq([ linked, "trailer" ])
      expect(described_class.next(phases: %w[update discussion])).to eq([ upd, "update" ])
      expect(described_class.next(phases: %w[discussion])).to eq([ discussion, "discussion" ])
    end
  end

  describe "update" do
    let(:topic) { create(:topic) }
    let!(:v1) { create(:message, topic: topic, created_at: 3.days.ago, is_patch_submission: true) }
    let(:judged) { create(:commit) }
    let!(:run) do
      create(:commit_topic, topic: topic, commit: judged, source: "trailer")
      create(:patchset_run, topic: topic, status: "done", mode: "trailer", through_message: v1, created_at: 2.days.ago).tap do |r|
        create(:commit_verdict, patchset_run: r, commit: judged)
      end
    end

    def scope = described_class.phase_scope("update").to_a

    it "skips a topic with nothing new" do
      expect(scope).to eq([])
    end

    it "takes a topic with a new trailer commit" do
      create(:commit_topic, topic: topic, commit: create(:commit), source: "trailer")
      expect(scope).to eq([ topic ])
      expect(described_class.next).to eq([ topic, "update" ])
    end

    it "takes a topic with patch mail after the through message, by date" do
      create(:message, topic: topic, created_at: 1.day.ago, is_patch_submission: true)
      expect(scope).to eq([ topic ])
    end

    it "ignores backfilled patch mail dated before the through message" do
      create(:message, topic: topic, created_at: 5.days.ago, is_patch_submission: true)
      expect(scope).to eq([])
    end

    it "is not hidden by a queued run behind the done one" do
      create(:commit_topic, topic: topic, commit: create(:commit), source: "trailer")
      create(:patchset_run, topic: topic, status: "queued", created_at: 1.hour.ago)
      expect(scope).to eq([ topic ])
    end

    it "counts all patch mail as new when the run has no through message" do
      run.update!(through_message_id: nil)
      expect(scope).to eq([ topic ])
    end

    context "when the run lists the patchsets it saw" do
      before { run.update!(bundle_index: { "patchsets" => [ { "message_id" => v1.id } ] }) }

      it "takes late patch mail dated before the through message" do
        create(:message, topic: topic, created_at: 5.days.ago, is_patch_submission: true)
        expect(scope).to eq([ topic ])
      end

      it "skips patch mail the run already saw, whatever its date" do
        seen = create(:message, topic: topic, created_at: 1.day.ago, is_patch_submission: true)
        run.update!(bundle_index: { "patchsets" => [ { "message_id" => v1.id }, { "message_id" => seen.id } ] })
        expect(scope).to eq([])
      end
    end

    context "when the run lists the patch mail it saw" do
      before { run.update!(bundle_index: { "patchsets" => [], "patch_mail_ids" => [ v1.id ] }) }

      it "takes any patch mail missing from the list, whatever its date" do
        create(:message, topic: topic, created_at: 5.days.ago, is_patch_submission: true)
        expect(scope).to eq([ topic ])
      end

      it "skips listed mail even when no patchset came out of it" do
        seen = create(:message, topic: topic, created_at: 1.day.ago, is_patch_submission: true)
        run.update!(bundle_index: { "patchsets" => [], "patch_mail_ids" => [ v1.id, seen.id ] })
        expect(scope).to eq([])
      end
    end

    it "falls back to dates when the run has no patchset list" do
      run.update!(bundle_index: { "mode" => "trailer" })
      create(:message, topic: topic, created_at: 5.days.ago, is_patch_submission: true)
      expect(scope).to eq([])
      create(:message, topic: topic, created_at: 1.day.ago, is_patch_submission: true)
      expect(scope).to eq([ topic ])
    end

    it "ignores plain discussion" do
      create(:message, topic: topic, created_at: 1.day.ago)
      expect(scope).to eq([])
    end

    %w[failed timeout claimed].each do |status|
      it "skips a topic whose newest run is #{status}" do
        create(:commit_topic, topic: topic, commit: create(:commit), source: "trailer")
        create(:patchset_run, topic: topic, status: status, mode: "update", created_at: 1.hour.ago, claimed_at: Time.current)
        expect(scope).to eq([])
      end
    end

    it "clears once a newer done run judged the commit" do
      fresh = create(:commit)
      create(:commit_topic, topic: topic, commit: fresh, source: "trailer")
      later = create(:patchset_run, topic: topic, status: "done", mode: "update", through_message: v1, created_at: 1.hour.ago)
      create(:commit_verdict, patchset_run: later, commit: judged)
      create(:commit_verdict, patchset_run: later, commit: fresh)
      expect(scope).to eq([])
    end
  end
end
