require "rails_helper"

RSpec.describe FeedEvents::Backfill do
  let(:now) { Time.current.change(usec: 0) }
  let(:alice) { create(:alias, :with_sent_messages) }
  let(:topic) { create(:topic, creator_alias: alice) }

  def mail(at, patch: false, **attrs)
    row = create(:message, topic: topic, sender: alice, created_at: at, **attrs)
    row.update_columns(is_patch_submission: true) if patch
    row
  end

  def branch(message, at, **attrs)
    row = create(:patch_branch, topic: topic, message: message, **attrs)
    row.update_columns(created_at: at)
    row
  end

  def run(patch_branch, **attrs)
    create(:patch_ci_run, patch_branch: patch_branch, **attrs)
  end

  def backfill(**options)
    described_class.new(now: now, **options).call
  end

  def stream
    FeedEvent.order(:id).map { |row| [ row.event_type, row.patch_ci_run_id || row.patch_branch_id || row.message_id ] }
  end

  let!(:fixture) do
    rows = {}
    rows[:ancient] = mail(now - 100.days, patch: true)
    rows[:ancient_branch] = branch(rows[:ancient], now - 100.days + 1.minute)
    rows[:ancient_run] = run(rows[:ancient_branch], status: "success", completed_at: now - 95.days)
    rows[:late_run] = run(rows[:ancient_branch], status: "tests_failed", completed_at: now - 5.days)

    rows[:plain] = mail(now - 10.days)
    rows[:patch] = mail(now - 9.days, patch: true)
    rows[:branch] = branch(rows[:patch], now - 9.days + 1.minute, attempted_at: now - 1.day)
    rows[:run] = run(rows[:branch], status: "success", completed_at: now - 9.days + 1.hour)
    rows[:undated_run] = run(rows[:branch], status: "infra_error", completed_at: nil)
    rows[:undated_run].update_columns(updated_at: now - 9.days + 2.hours)
    rows[:running] = run(rows[:branch], status: "running")
    rows[:pending] = mail(now - 8.days, state: "pending")
    rows[:lineage_patch] = mail(now - 7.days, patch: true)
    rows[:lineage_branch] = branch(rows[:lineage_patch], now - 7.days + 1.minute, lineage_only: true)
    rows[:failed_patch] = mail(now - 6.days, patch: true)
    rows[:failed_branch] = branch(rows[:failed_patch], now - 6.days + 1.minute, status: "failed", failure_stage: "apply")
    FeedEvent.delete_all
    rows
  end

  let(:history) do
    [
      [ "message.received", fixture[:plain].id ],
      [ "message.received", fixture[:patch].id ],
      [ "patchset.posted", fixture[:patch].id ],
      [ "branch.created", fixture[:branch].id ],
      [ "ci.completed", fixture[:run].id ],
      [ "ci.completed", fixture[:undated_run].id ],
      [ "message.received", fixture[:pending].id ],
      [ "message.received", fixture[:lineage_patch].id ],
      [ "patchset.posted", fixture[:lineage_patch].id ],
      [ "message.received", fixture[:failed_patch].id ],
      [ "patchset.posted", fixture[:failed_patch].id ],
      [ "branch.created", fixture[:failed_branch].id ],
      [ "ci.completed", fixture[:late_run].id ]
    ]
  end

  def in_time_order
    FeedEvent.order(:id).pluck(:created_at) == FeedEvent.order(:created_at, :id).pluck(:created_at)
  end

  def expired?(id)
    Api::EventFeed.new(since: Api::EventFeed.encode(id)).page
    false
  rescue Api::EventFeed::Expired
    true
  end

  it "writes the window as one stream in the order things happened" do
    result = backfill

    expect(stream).to eq(history)
    expect(in_time_order).to be(true)
    expect(FeedEvent.where("created_at <> occurred_at")).to be_empty
    expect(result.added).to eq("message.received" => 5, "patchset.posted" => 3, "branch.created" => 2,
                               "ci.completed" => 3)
    expect(result.renumbered).to eq(0)
    expect(result.from).to eq(now - 90.days)
    expect(result.to).to eq(now)
  end

  it "fills the references and times as the recorder does" do
    backfill

    posted = FeedEvent.find_by!(event_type: "patchset.posted", message_id: fixture[:patch].id)
    expect(posted).to have_attributes(author_person_id: alice.person_id, patch_branch_id: nil, patch_ci_run_id: nil,
                                      occurred_at: now - 9.days, first_run: nil, previous_status: nil,
                                      verdict_changed: nil)

    created = FeedEvent.find_by!(event_type: "branch.created")
    expect(created).to have_attributes(message_id: fixture[:patch].id, author_person_id: alice.person_id,
                                       patch_branch_id: fixture[:branch].id, patch_ci_run_id: nil,
                                       occurred_at: now - 9.days + 1.minute, verdict_changed: nil)

    completed = FeedEvent.find_by!(patch_ci_run_id: fixture[:undated_run].id)
    expect(completed).to have_attributes(message_id: fixture[:patch].id, author_person_id: alice.person_id,
                                         patch_branch_id: fixture[:branch].id,
                                         occurred_at: now - 9.days + 2.hours, created_at: now - 9.days + 2.hours)
  end

  it "says for each run whether it is the first of its branch and what the one before it said" do
    repeat = run(fixture[:branch], status: "infra_error", completed_at: now - 2.days)
    fixed = run(fixture[:branch], status: "success", completed_at: now - 1.day)
    [ fixture[:run], fixture[:undated_run], fixture[:running], repeat, fixed ].each_with_index do |row, i|
      row.update_columns(created_at: now - 9.days + i.hours)
    end
    fixture[:ancient_run].update_columns(created_at: now - 95.days)
    fixture[:late_run].update_columns(created_at: now - 5.days)

    backfill

    facts = FeedEvent.where(event_type: "ci.completed").to_h do |row|
      [ row.patch_ci_run_id, [ row.first_run, row.previous_status, row.verdict_changed ] ]
    end
    expect(facts).to eq(
      fixture[:run].id => [ true, nil, true ],
      fixture[:undated_run].id => [ false, "success", true ],
      repeat.id => [ false, "infra_error", false ],
      fixed.id => [ false, "infra_error", true ],
      fixture[:late_run].id => [ false, "success", true ]
    )
  end

  it "takes a shorter window" do
    result = backfill(days: 6)

    expect(stream).to eq(history.last(4))
    expect(result.added.values.sum).to eq(4)
  end

  it "does not go past the retention of the feed" do
    expect { described_class.new(days: 91) }.to raise_error(ArgumentError, /90/)
    expect { described_class.new(days: 0) }.to raise_error(ArgumentError)
  end

  it "inserts and renumbers nothing on a second run" do
    backfill
    before = FeedEvent.order(:id).pluck(:id, :created_at)

    again = backfill
    writes = captured_queries { backfill }.grep(/\A\s*UPDATE/i)

    expect(FeedEvent.order(:id).pluck(:id, :created_at)).to eq(before)
    expect([ again.added, again.renumbered ]).to eq([ {}, 0 ])
    expect(writes).to be_empty
  end

  it "reports and writes nothing on a dry run" do
    live = mail(now - 1.hour)
    recorded(at: now - 2.minutes) { FeedEvents::Recorder.message_received(live) }
    mail(now - 1.minute)
    before = FeedEvent.pluck(:id, :created_at)
    sequence = FeedEvent.lease_connection.select_value("SELECT last_value FROM feed_events_id_seq")

    result = backfill(dry_run: true)

    expect(FeedEvent.pluck(:id, :created_at)).to eq(before)
    expect(FeedEvent.lease_connection.select_value("SELECT last_value FROM feed_events_id_seq")).to eq(sequence)
    expect(result.added.values.sum).to eq(14)
    expect(result.added).to include("message.received" => 6)
    expect(result.renumbered).to eq(15)
    expect(result.dry_run).to be(true)
  end

  it "previews no renumbering when what is missing is newer than every row" do
    backfill
    mail(now - 1.minute)

    expect(backfill(dry_run: true)).to have_attributes(added: { "message.received" => 1 }, renumbered: 0)
    expect(backfill).to have_attributes(added: { "message.received" => 1 }, renumbered: 0)
  end

  context "with events recorded before the backfill ran" do
    let!(:early) { mail(now - 1.hour) }
    let!(:missed) { mail(now - 1.minute) }
    let!(:live) do
      recorded(at: now - 2.minutes) { FeedEvents::Recorder.message_received(early) }
      second = mail(now - 30.seconds)
      recorded(at: now - 20.seconds) { FeedEvents::Recorder.message_received(second) }
      FeedEvent.order(:id).to_a
    end
    let(:recent) { [ live.first.message_id, missed.id, live.last.message_id ].map { |id| [ "message.received", id ] } }

    it "adds what is missing and renumbers the whole feed in time order" do
      result = backfill

      expect(stream).to eq(history + recent)
      expect(in_time_order).to be(true)
      expect(FeedEvent.minimum(:id)).to be > live.last.id + 1
      expect(result.added.values.sum).to eq(14)
      expect(result.renumbered).to eq(16)
      expect(FeedEvent.find_by!(message_id: missed.id)).to have_attributes(created_at: now - 1.minute)
      expect(FeedEvent.find_by!(message_id: early.id)).to have_attributes(created_at: now - 2.minutes,
                                                                          occurred_at: early.created_at)
    end

    it "leaves no position of before the run valid" do
      backfill

      expect(live.map { |row| expired?(row.id) }).to eq([ true, true ])
      expect(Api::EventFeed.new(since: "1h").page.events.map(&:message_id)).to eq(recent.map(&:last))
    end

    it "gives the next event an id above the renumbered ones" do
      backfill

      later = message_event(topic: topic, sender: alice)
      expect(later.id).to eq(FeedEvent.maximum(:id))
      expect(FeedEvent.count).to eq(17)
    end

    it "does nothing on the next run" do
      backfill
      before = FeedEvent.order(:id).pluck(:id, :created_at)

      expect(backfill).to have_attributes(added: {}, renumbered: 0)
      expect(FeedEvent.order(:id).pluck(:id, :created_at)).to eq(before)
    end

    it "finishes what a run that died left behind" do
      slices = 0
      expect {
        described_class.new(now: now).call { raise "died" if (slices += 1) > 82 }
      }.to raise_error("died")
      partial = FeedEvent.order(:id).to_a
      expect(partial.size).to be_between(3, 15)
      expect(in_time_order).to be(false)

      result = backfill

      expect(stream).to eq(history + recent)
      expect(in_time_order).to be(true)
      expect(result.added.values.sum).to eq(16 - partial.size)
      expect(result.renumbered).to eq(16)
      expect(FeedEvent.group(:event_type, :message_id, :patch_branch_id, :patch_ci_run_id).having("COUNT(*) > 1").count)
        .to be_empty
      expect(partial.map { |row| expired?(row.id) }.uniq).to eq([ true ])
      expect(backfill).to have_attributes(added: {}, renumbered: 0)
    end
  end

  it "renumbers a feed that is out of order with nothing to add" do
    backfill
    first = FeedEvent.order(:id).first
    first.update_columns(created_at: now - 1.day)

    expect(backfill(dry_run: true)).to have_attributes(added: {}, renumbered: 13)
    result = backfill

    expect(result).to have_attributes(added: {}, renumbered: 13)
    expect(in_time_order).to be(true)
    expect(expired?(first.id)).to be(true)
  end

  it "reports the slices as it goes" do
    seen = []
    described_class.new(now: now, days: 10).call { |from, counts| seen << [ from, counts.values.sum ] }

    expect(seen.map(&:first)).to eq(seen.map(&:first).sort)
    expect(seen.sum(&:last)).to eq(13)
    expect(seen.size).to be > 5
  end
end
