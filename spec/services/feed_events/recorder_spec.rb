require "rails_helper"

RSpec.describe FeedEvents::Recorder do
  let(:message) { create(:message, created_at: Time.zone.parse("2020-03-04 05:06:07")) }
  let(:branch) do
    create(:patch_branch, message: message, topic: message.topic,
           attempted_at: Time.zone.parse("2026-01-02 03:04:05"))
  end

  def events(type)
    FeedEvent.where(event_type: type)
  end

  describe ".message_received" do
    it "stores the message, its sender and the mail date" do
      described_class.message_received(message)

      event = events("message.received").sole
      expect(event).to have_attributes(message_id: message.id, author_person_id: message.sender_person_id,
                                       patch_branch_id: nil, patch_ci_run_id: nil,
                                       first_run: nil, previous_status: nil, verdict_changed: nil)
      expect(event.occurred_at).to eq(message.created_at)
    end

    it "is stamped by the database clock, at the insert" do
      message
      travel_to(3.years.ago) { described_class.message_received(message) }

      expect(events("message.received").where("created_at > clock_timestamp() AT TIME ZONE 'UTC' - interval '1 minute'")
                                       .where("created_at > now() AT TIME ZONE 'UTC'").count).to eq(1)
    end

    it "records once" do
      2.times { described_class.message_received(message) }
      expect(events("message.received").count).to eq(1)
    end
  end

  describe ".patchset_posted" do
    it "records once per message, next to the received event" do
      described_class.message_received(message)
      2.times { described_class.patchset_posted(message) }

      event = events("patchset.posted").sole
      expect(event).to have_attributes(message_id: message.id, author_person_id: message.sender_person_id)
      expect(event.occurred_at).to eq(message.created_at)
      expect(event.id).to be > events("message.received").sole.id
    end
  end

  describe ".branch_created" do
    it "stores the branch with the message sender and the attempt time" do
      2.times { described_class.branch_created(branch) }

      event = events("branch.created").sole
      expect(event).to have_attributes(message_id: message.id, author_person_id: message.sender_person_id,
                                       patch_branch_id: branch.id, patch_ci_run_id: nil, verdict_changed: nil)
      expect(event.occurred_at).to eq(branch.attempted_at)
    end

    it "skips a lineage-only row" do
      branch.update_columns(lineage_only: true)
      described_class.branch_created(branch)
      expect(FeedEvent.count).to eq(0)
    end
  end

  describe ".ci_completed" do
    it "stores the run with the message sender and the completion time" do
      run = create(:patch_ci_run, patch_branch: branch, status: "tests_failed",
                   completed_at: Time.zone.parse("2026-02-03 04:05:06"))
      2.times { described_class.ci_completed(run) }

      event = events("ci.completed").sole
      expect(event).to have_attributes(message_id: message.id, author_person_id: message.sender_person_id,
                                       patch_branch_id: branch.id, patch_ci_run_id: run.id)
      expect(event.occurred_at).to eq(run.completed_at)
    end

    def facts(run)
      events("ci.completed").where(patch_ci_run_id: run.id).pick(:first_run, :previous_status, :verdict_changed)
    end

    def finished(status, at, on: branch)
      create(:patch_ci_run, patch_branch: on, status: status, created_at: at).tap do |run|
        described_class.ci_completed(run)
      end
    end

    it "says whether the run is the first of the branch and what the one before it said" do
      create(:patch_ci_run, patch_branch: branch, status: "running", created_at: 5.days.ago)
      other = create(:patch_branch, topic: message.topic)
      finished("build_failed", 4.days.ago, on: other)

      first = finished("success", 3.days.ago)
      repeat = finished("success", 2.days.ago)
      broken = finished("tests_failed", 1.day.ago)

      expect(facts(first)).to eq([ true, nil, true ])
      expect(facts(repeat)).to eq([ false, "success", false ])
      expect(facts(broken)).to eq([ false, "success", true ])
    end

    it "takes the newest of the other runs by created_at, then id" do
      at = 2.days.ago
      finished("success", at)
      finished("tests_failed", at)

      expect(facts(finished("tests_failed", 1.day.ago))).to eq([ false, "tests_failed", false ])
    end

    it "replaces the event of a run whose verdict changed, with a new id" do
      finished("success", 2.days.ago)
      run = finished("infra_error", 1.day.ago)
      before = events("ci.completed").where(patch_ci_run_id: run.id).sole
      expect(facts(run)).to eq([ false, "success", true ])

      run.update_columns(status: "success")
      described_class.ci_completed(run, replace: true)

      after = events("ci.completed").where(patch_ci_run_id: run.id).sole
      expect(after.id).to be > before.id
      expect(after.id).to eq(FeedEvent.maximum(:id))
      expect(facts(run)).to eq([ false, "success", true ])
    end

    it "falls back to now without a completion time" do
      run = create(:patch_ci_run, patch_branch: branch, status: "infra_error", completed_at: nil)
      described_class.ci_completed(run)
      expect(events("ci.completed").sole.occurred_at).to be_within(1.minute).of(Time.current)
    end

    it "skips a run that is not finished" do
      run = create(:patch_ci_run, patch_branch: branch, status: "running")
      described_class.ci_completed(run)
      expect(FeedEvent.count).to eq(0)
    end
  end

  describe ".message_redated" do
    it "moves occurred_at of the message events only" do
      described_class.message_received(message)
      described_class.patchset_posted(message)
      described_class.branch_created(branch)
      message.update_columns(created_at: Time.zone.parse("2019-01-01 00:00:00"))

      described_class.message_redated(message)

      expect(FeedEvent.where(event_type: FeedEvent::MESSAGE_TYPES).pluck(:occurred_at).uniq)
        .to eq([ message.created_at ])
      expect(events("branch.created").sole.occurred_at).to eq(branch.attempted_at)
    end
  end

  describe "failures" do
    it "swallows and logs an insert that raises" do
      allow(FeedEvent).to receive(:insert_all).and_raise(ActiveRecord::StatementInvalid, "boom")
      allow(Rails.logger).to receive(:warn)

      expect(described_class.message_received(message)).to be_nil
      expect(described_class.ci_completed(create(:patch_ci_run, patch_branch: branch))).to be_nil

      expect(Rails.logger).to have_received(:warn).with(/message\.received.*#{message.id}.*boom/)
      expect(Rails.logger).to have_received(:warn).with(/ci\.completed.*boom/)
    end

    it "swallows a nil subject" do
      allow(Rails.logger).to receive(:warn)
      expect { described_class.message_received(nil) }.not_to raise_error
      expect { described_class.branch_created(nil) }.not_to raise_error
    end

    it "goes on after a real database error, in a transaction and without one" do
      gone = build_stubbed(:message)
      other = create(:message)
      allow(Rails.logger).to receive(:warn)

      Message.transaction do
        described_class.message_received(gone)
        described_class.message_received(message)
      end
      described_class.message_received(gone)
      described_class.message_received(other)

      expect(Rails.logger).to have_received(:warn).with(/ForeignKey|InvalidForeignKey/).twice
      expect(events("message.received").order(:id).pluck(:message_id)).to eq([ message.id, other.id ])
      expect(Message.where(id: message.id).count).to eq(1)
    end

    it "swallows a subject that cannot be read" do
      broken = instance_double(Message, id: 5, sender_person_id: nil)
      allow(broken).to receive(:created_at).and_raise(ActiveRecord::StatementInvalid, "boom")
      allow(Rails.logger).to receive(:warn)

      expect(described_class.message_received(broken)).to be_nil
      expect(described_class.message_redated(broken)).to be_nil
      expect(Rails.logger).to have_received(:warn).with(/boom/).twice
    end
  end

  # the transaction of the example does not count: an after-commit hook runs when the outermost block ends
  describe "inside a transaction" do
    it "inserts when the outermost block commits, in the order of the calls" do
      Message.transaction do
        Message.transaction(requires_new: true) do
          described_class.message_received(message)
          described_class.patchset_posted(message)
        end
        described_class.branch_created(branch)
        expect(FeedEvent.count).to eq(0)
      end

      expect(FeedEvent.order(:id).pluck(:event_type)).to eq(%w[message.received patchset.posted branch.created])
    end

    it "inserts nothing when the block is rolled back" do
      Message.transaction do
        described_class.message_received(message)
        raise ActiveRecord::Rollback
      end

      expect(FeedEvent.count).to eq(0)
    end

    it "redates after the insert of the same transaction" do
      Message.transaction do
        described_class.message_received(message)
        message.update_columns(created_at: Time.zone.parse("2019-01-01 00:00:00"))
        described_class.message_redated(message)
      end

      expect(events("message.received").sole.occurred_at).to eq(Time.zone.parse("2019-01-01 00:00:00"))
    end
  end
end
