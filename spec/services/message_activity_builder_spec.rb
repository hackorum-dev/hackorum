# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MessageActivityBuilder do
  let(:topic) { create(:topic) }
  let(:sender_user) { create(:user) }
  let(:sender_alias) { create(:alias, user: sender_user) }
  let(:message) { create(:message, topic: topic, sender: sender_alias) }
  let(:builder) { described_class.new(message) }

  describe "#process!" do
    context "auto-starring" do
      it "stars topic for registered user sender" do
        expect {
          builder.process!
        }.to change { TopicStar.count }.by(1)

        star = TopicStar.last
        expect(star.user).to eq(sender_user)
        expect(star.topic).to eq(topic)
      end

      it "does not star for guest sender (no user_id)" do
        guest_alias = create(:alias, user: nil)
        guest_message = create(:message, topic: topic, sender: guest_alias)
        guest_builder = described_class.new(guest_message)

        expect {
          guest_builder.process!
        }.not_to change { TopicStar.count }
      end

      it "is idempotent - handles existing stars gracefully" do
        # Create initial star
        TopicStar.create!(user: sender_user, topic: topic)

        # Should not raise error or create duplicate
        expect {
          builder.process!
        }.not_to change { TopicStar.count }

        # Should still have exactly one star
        expect(TopicStar.where(user: sender_user, topic: topic).count).to eq(1)
      end

      it "handles race conditions with RecordNotUnique" do
        # Simulate race condition by stubbing to raise then succeed
        allow(TopicStar).to receive(:find_or_create_by).and_raise(ActiveRecord::RecordNotUnique)

        # Should not raise error
        expect {
          builder.process!
        }.not_to raise_error
      end
    end

    context "marking message as read for sender" do
      it "marks the message as read for registered user sender" do
        builder.process!

        expect(MessageReadRange.covering?(user: sender_user, topic: topic, message_id: message.id)).to be true
      end

      it "marks thread awareness for registered user sender" do
        builder.process!

        expect(ThreadAwareness.covering?(user: sender_user, topic: topic, message_id: message.id)).to be true
      end

      it "does not mark message as read for guest sender" do
        guest_alias = create(:alias, user: nil)
        guest_message = create(:message, topic: topic, sender: guest_alias)
        guest_builder = described_class.new(guest_message)

        expect {
          guest_builder.process!
        }.not_to change { MessageReadRange.count }
      end

      it "does not mark thread awareness for guest sender" do
        guest_alias = create(:alias, user: nil)
        guest_message = create(:message, topic: topic, sender: guest_alias)
        guest_builder = described_class.new(guest_message)

        expect {
          guest_builder.process!
        }.not_to change { ThreadAwareness.count }
      end

      it "extends existing thread awareness" do
        # Create initial awareness
        ThreadAwareness.mark_until(user: sender_user, topic: topic, until_message_id: message.id - 10)

        builder.process!

        awareness = ThreadAwareness.find_by(user: sender_user, topic: topic)
        expect(awareness.aware_until_message_id).to eq(message.id)
      end
    end

    context "activity creation" do
      let(:starring_user1) { create(:user) }
      let(:starring_user2) { create(:user) }

      before do
        create(:topic_star, user: starring_user1, topic: topic)
        create(:topic_star, user: starring_user2, topic: topic)
      end

      it "creates activities for all users who starred the topic except the sender" do
        expect {
          builder.process!
        }.to change { Activity.count }.by(2) # 2 starring users, sender is excluded

        activities = Activity.where(activity_type: "topic_message_received")
        expect(activities.pluck(:user_id)).to match_array([ starring_user1.id, starring_user2.id ])
      end

      it "does not create an activity for the sender even if they starred the topic" do
        # Sender also has the topic starred
        create(:topic_star, user: sender_user, topic: topic)

        builder.process!

        sender_activity = Activity.find_by(user: sender_user, subject: message)
        expect(sender_activity).to be_nil
      end

      it "does not mark other users' activities as read" do
        builder.process!

        other_activities = Activity.where(user_id: [ starring_user1.id, starring_user2.id ])
        expect(other_activities.all? { |a| a.read_at.nil? }).to be true
      end

      it "includes correct payload data" do
        builder.process!

        activity = Activity.find_by(user: starring_user1, subject: message)
        expect(activity.payload).to eq({
          "topic_id" => topic.id,
          "message_id" => message.id
        })
      end

      it "uses topic_message_received activity type" do
        builder.process!

        activities = Activity.where(subject: message)
        expect(activities.pluck(:activity_type).uniq).to eq([ "topic_message_received" ])
      end

      it "sets subject polymorphically to Message" do
        builder.process!

        activity = Activity.find_by(user: starring_user1)
        expect(activity.subject_type).to eq("Message")
        expect(activity.subject_id).to eq(message.id)
        expect(activity.subject).to eq(message)
      end

      it "sets hidden to false" do
        builder.process!

        activities = Activity.where(subject: message)
        expect(activities.all?(&:hidden)).to be false
      end
    end

    context "edge cases" do
      it "handles topic with no stars" do
        expect {
          builder.process!
        }.not_to change { Activity.count }

        expect(TopicStar.exists?(user: sender_user, topic: topic)).to be true

        activity = Activity.find_by(user: sender_user, subject: message)
        expect(activity).to be_nil
      end

      it "handles sender who is not a registered user" do
        guest_alias = create(:alias, user: nil)
        guest_message = create(:message, topic: topic, sender: guest_alias)
        guest_builder = described_class.new(guest_message)

        starring_user = create(:user)
        create(:topic_star, user: starring_user, topic: topic)

        expect {
          guest_builder.process!
        }.to change { Activity.count }.by(1)

        activity = Activity.find_by(user: starring_user)
        expect(activity).to be_present
        expect(activity.read_at).to be_nil

        expect(TopicStar.where(topic: topic).pluck(:user_id)).to eq([ starring_user.id ])
      end

      it "handles sender who has already starred the topic" do
        create(:topic_star, user: sender_user, topic: topic)

        other_user = create(:user)
        create(:topic_star, user: other_user, topic: topic)

        expect {
          builder.process!
        }.to change { Activity.count }.by(1)

        sender_activity = Activity.find_by(user: sender_user, subject: message)
        expect(sender_activity).to be_nil

        other_activity = Activity.find_by(user: other_user, subject: message)
        expect(other_activity.read_at).to be_nil

        expect(TopicStar.where(user: sender_user, topic: topic).count).to eq(1)
      end

      it "wraps operations in transaction" do
        allow_any_instance_of(described_class).to receive(:fan_out_to_starring_users)
          .and_raise(StandardError, "Simulated error")

        expect {
          expect { builder.process! }.to raise_error(StandardError, "Simulated error")
        }.not_to change { TopicStar.count }
      end
    end
  end
end
