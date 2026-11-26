require "rails_helper"

RSpec.describe Classify::Queue do
  let(:now) { Time.zone.parse("2026-11-26 12:00") }
  let(:hackers) { create(:mailing_list, identifier: "pgsql-hackers") }

  before do
    travel_to(now)
    create(:release_tag, name: "REL_16_BETA1", released_at: Time.zone.parse("2024-05-21"))
  end

  after { travel_back }

  def thread(first_at:, n: 1, last_at: nil, list: hackers)
    topic = create(:topic, created_at: first_at)
    n.times { |i| create(:message, topic:, created_at: first_at + i.minutes) }
    create(:message, topic:, created_at: last_at) if last_at
    create(:topic_mailing_list, topic:, mailing_list: list)
    topic.reload
  end

  def run(topic, at: Time.current, **attrs)
    create(:classification_run, **{ topic:, created_at: at, finished_at: at }.merge(attrs))
  end

  def add_message(topic)
    create(:message, topic:, created_at: Time.current)
  end

  def scope(phase) = described_class.phase_scope(phase).to_a

  def phases_of(topic)
    described_class::PHASES.select { |p| described_class.phase_scope(p).exists?(topic.id) }
  end

  it "puts a 7h old thread in new, a 2h old one nowhere" do
    older = thread(first_at: 3.days.ago)
    young = thread(first_at: 7.hours.ago)
    baby = thread(first_at: 2.hours.ago)

    expect(scope("new")).to eq([ young, older ])
    expect(phases_of(baby)).to eq([])
    travel 4.hours + 1.minute
    expect(scope("new")).to eq([ baby, young, older ])
  end

  it "puts a 20 day old unclassified window thread in backfill, not new" do
    quiet = thread(first_at: 30.days.ago)
    old = thread(first_at: 20.days.ago)
    revived = thread(first_at: 40.days.ago, last_at: 1.hour.ago)

    expect(scope("backfill")).to eq([ revived, old, quiet ])
    expect(scope("new")).to eq([])
  end

  it "skips threads outside the lists and before the window" do
    general = create(:mailing_list, identifier: "pgsql-general")
    off_list = [ thread(first_at: 7.hours.ago, list: general), thread(first_at: 20.days.ago, list: general) ]
    ancient = thread(first_at: Time.zone.parse("2023-01-01"), n: 3)
    merged = thread(first_at: 7.hours.ago)
    merged.update_columns(merged_into_topic_id: ancient.id)
    done_merged = thread(first_at: 20.days.ago)
    run(done_merged, at: 10.days.ago)
    add_message(done_merged)
    done_merged.update_columns(merged_into_topic_id: ancient.id)

    [ *off_list, ancient, merged, done_merged ].each { |t| expect(phases_of(t)).to eq([]) }
  end

  it "never rechecks without new messages" do
    topic = thread(first_at: 20.days.ago, n: 2)
    run(topic)
    travel 40.days
    expect(phases_of(topic)).to eq([])
  end

  it "rechecks after the backoff" do
    once = thread(first_at: 20.days.ago)
    run(once)
    add_message(once)
    thrice = thread(first_at: 30.days.ago)
    run(thrice, at: 20.days.ago)
    run(thrice, at: 10.days.ago)
    run(thrice)
    add_message(thrice)

    travel 12.hours
    expect(scope("recheck")).to eq([])
    travel 12.hours
    expect(scope("recheck")).to eq([ once ])
    travel 2.days
    expect(scope("recheck")).to eq([ once ])
    travel 1.day
    expect(scope("recheck")).to eq([ once, thrice ])
    expect(phases_of(thrice)).to eq(%w[recheck])
  end

  it "waits 90 days on settled threads" do
    group = create(:feature_group)
    same = { kind: "feature", size: "major", enhancement: false, not_a_bug: false, feature_group_id: group.id }
    settled = thread(first_at: 200.days.ago, n: 30)
    run(settled, at: 100.days.ago, **same)
    run(settled, **same)
    add_message(settled)
    changed = thread(first_at: 200.days.ago, n: 30)
    run(changed, at: 100.days.ago, **same.merge(size: "moderate"))
    run(changed, **same)
    add_message(changed)
    flagged = thread(first_at: 200.days.ago, n: 30)
    run(flagged, at: 100.days.ago, **same.merge(enhancement: true))
    run(flagged, **same)
    add_message(flagged)
    short = thread(first_at: 200.days.ago, n: 2)
    run(short, at: 100.days.ago, **same)
    run(short, **same)
    add_message(short)

    travel 30.days
    expect(scope("recheck")).to contain_exactly(changed, flagged, short)
    travel 61.days
    expect(scope("recheck")).to contain_exactly(changed, flagged, short, settled)
  end

  it "never rechecks fully locked threads" do
    Classify::Setup.call!
    admin = create(:user, admin: true)
    due = lambda do |tags: %w[feature minor], lock: nil, membership: nil|
      topic = thread(first_at: 20.days.ago)
      Classify::BotNote.new(topic).write!(tags)
      note = Classify::BotNote.new(topic).note
      note.update_columns(deleted_at: Time.current) if lock == :deleted
      note.update_columns(last_editor_id: admin.id) if lock == :edited
      note.update_columns(last_editor_id: Classify.bot_user.id) if lock == :bot
      create(:feature_group_topic, topic:, source: membership) if membership
      run(topic, at: 10.days.ago)
      add_message(topic)
      topic
    end

    deleted_alone = due.call(lock: :deleted)
    edited_human = due.call(lock: :edited, membership: "human")
    edited_llm = due.call(lock: :edited, membership: "llm")
    open_human = due.call(membership: "human")
    bot_edited = due.call(lock: :bot)
    no_note = thread(first_at: 20.days.ago)
    run(no_note, at: 10.days.ago)
    add_message(no_note)

    expect(scope("recheck")).to contain_exactly(edited_llm, open_human, bot_edited, no_note)
    expect(phases_of(deleted_alone)).to eq([])
    expect(phases_of(edited_human)).to eq([])
  end

  it "holds failed and claimed threads, releases stale claims on sweep" do
    failed = thread(first_at: 7.hours.ago)
    run(failed, status: "failed", failure_kind: "schema")
    timed_out = thread(first_at: 20.days.ago)
    run(timed_out, status: "timeout")
    failed_recheck = thread(first_at: 20.days.ago)
    run(failed_recheck, at: 10.days.ago)
    run(failed_recheck, at: 5.days.ago, status: "failed")
    add_message(failed_recheck)
    claimed = thread(first_at: 7.hours.ago)
    claim = run(claimed, status: "claimed", claimed_at: Time.current, finished_at: nil)
    claimed_recheck = thread(first_at: 20.days.ago)
    run(claimed_recheck, at: 10.days.ago)
    add_message(claimed_recheck)
    run(claimed_recheck, status: "claimed", claimed_at: Time.current, finished_at: nil)

    [ failed, timed_out, failed_recheck, claimed, claimed_recheck ].each { |t| expect(phases_of(t)).to eq([]) }
    expect(described_class.sweep!).to eq(0)

    travel 2.hours
    expect(phases_of(claimed)).to eq([])
    expect(described_class.sweep!).to eq(2)
    expect(ClassificationRun.exists?(claim.id)).to be(false)
    expect(phases_of(claimed)).to eq(%w[new])
    expect(phases_of(claimed_recheck)).to eq(%w[recheck])
    [ failed, timed_out, failed_recheck ].each { |t| expect(phases_of(t)).to eq([]) }
  end

  it "holds a claim behind a later done run" do
    topic = thread(first_at: 20.days.ago)
    run(topic, at: 10.days.ago)
    run(topic, status: "claimed", claimed_at: Time.current, finished_at: nil)
    run(topic, worker: "local")
    add_message(topic)

    travel 3.days
    expect(phases_of(topic)).to eq([])
    described_class.sweep!
    expect(phases_of(topic)).to eq(%w[recheck])
  end

  it "orders phases new, recheck, backfill" do
    expect(described_class.next).to be_nil
    backfill = thread(first_at: 20.days.ago)
    recheck = thread(first_at: 30.days.ago)
    run(recheck, at: 10.days.ago, phase: "backfill")
    add_message(recheck)
    fresh = thread(first_at: 7.hours.ago)

    expect(described_class.next).to eq([ fresh, "new" ])
    expect(described_class.next(phases: %w[recheck backfill])).to eq([ recheck, "recheck" ])
    expect(described_class.next(phases: %w[backfill])).to eq([ backfill, "backfill" ])
    expect(described_class.next(phases: %w[backfill recheck new])).to eq([ fresh, "new" ])
    expect { described_class.phase_scope("nope") }.to raise_error(ArgumentError)
  end

  it "counts per phase" do
    thread(first_at: 7.hours.ago)
    thread(first_at: 20.days.ago)
    thread(first_at: 25.days.ago)
    claimed = thread(first_at: 8.hours.ago)
    run(claimed, status: "claimed", phase: "new", claimed_at: Time.current, finished_at: nil)
    done = thread(first_at: 30.days.ago)
    run(done, at: 10.days.ago, phase: "backfill")
    add_message(done)

    expect(described_class.counts).to eq(
      "new" => { remaining: 1, claimed: 1, done: 0 },
      "recheck" => { remaining: 1, claimed: 0, done: 0 },
      "backfill" => { remaining: 2, claimed: 0, done: 1 }
    )
  end
end
