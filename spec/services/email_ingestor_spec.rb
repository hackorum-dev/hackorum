require "rails_helper"

RSpec.describe EmailIngestor do
  describe "#normalize_subject_for_threading" do
    it "strips prefixes, list tags, and (fwd)" do
      ingestor = described_class.new
      normalized = ingestor.send(:normalize_subject_for_threading, "Re: [HACKERS] Re: [PORTS] (fwd) Topic ABC")
      expect(normalized).to eq("topic abc")
    end
  end

  describe "#fallback_thread_lookup" do
    let!(:topic) { create(:topic) }
    let!(:root_msg) { create(:message, topic: topic, subject: "Anyone working on linux Alpha?", created_at: 2.days.ago) }
    let!(:root_aw) { create(:message, topic: topic, subject: "mmap and MAP_ANON", created_at: 2.days.ago) }
    let(:ingestor) { described_class.new }

    it "matches subjects with multiple prefixes and list tags" do
      subject = "Re: [HACKERS] Re: [PORTS] Anyone working on linux Alpha?"
      found = ingestor.send(:fallback_thread_lookup, subject, message_id: nil, references: [], sent_at: Time.current)
      expect(found).to eq(root_msg)
    end

    it "matches AW prefix with list tags to plain subject" do
      subject = "AW: [HACKERS] mmap and MAP_ANON"
      found = ingestor.send(:fallback_thread_lookup, subject, message_id: nil, references: [], sent_at: Time.current)
      expect(found).to eq(root_aw)
    end
  end

  describe "#ingest_raw with message activities" do
    let(:ingestor) { described_class.new }
    let(:user1) { create(:user, username: "user1") }
    let(:user2) { create(:user, username: "user2") }

    let(:raw_email) do
      <<~EMAIL
        From: sender@example.com
        To: recipient@example.com
        Subject: Test Subject
        Message-ID: <test123@example.com>
        Date: #{Time.current.rfc2822}

        This is the email body.
      EMAIL
    end

    before do
      allow_any_instance_of(described_class).to receive(:create_users).and_return([])
      allow_any_instance_of(described_class).to receive(:add_mentions)
      allow_any_instance_of(described_class).to receive(:handle_attachments)
    end

    context "auto-starring" do
      it "creates star for registered sender" do
        sender_alias = create(:alias, email: "sender@example.com", user: user1)
        allow_any_instance_of(described_class).to receive(:build_from_aliases).and_return([ sender_alias ])

        expect {
          ingestor.ingest_raw(raw_email)
        }.to change { TopicStar.count }.by(1)

        star = TopicStar.last
        expect(star.user).to eq(user1)
        expect(star.topic).to be_present
      end

      it "does not create star for guest sender" do
        guest_alias = create(:alias, email: "sender@example.com", user: nil)
        allow_any_instance_of(described_class).to receive(:build_from_aliases).and_return([ guest_alias ])

        expect {
          ingestor.ingest_raw(raw_email)
        }.not_to change { TopicStar.count }
      end

      it "is idempotent - handles existing stars" do
        sender_alias = create(:alias, email: "sender@example.com", user: user1)
        allow_any_instance_of(described_class).to receive(:build_from_aliases).and_return([ sender_alias ])

        first_message = ingestor.ingest_raw(raw_email)
        expect(TopicStar.count).to eq(1)

        reply_email = raw_email.gsub("<test123@example.com>", "<test456@example.com>")
        reply_email = reply_email.gsub("Subject: Test Subject", "Subject: Re: Test Subject\nIn-Reply-To: <test123@example.com>")

        expect {
          ingestor.ingest_raw(reply_email)
        }.not_to change { TopicStar.count }

        expect(TopicStar.where(user: user1, topic: first_message.topic).count).to eq(1)
      end
    end

    context "activity creation" do
      it "creates activities for users who have starred the topic (excluding sender)" do
        sender_alias = create(:alias, email: "sender@example.com", user: user1)
        allow_any_instance_of(described_class).to receive(:build_from_aliases).and_return([ sender_alias ])

        first_message = ingestor.ingest_raw(raw_email)
        topic = first_message.topic

        create(:topic_star, user: user2, topic: topic)

        reply_sender = create(:user, username: "replier")
        reply_sender_alias = create(:alias, email: "replier@example.com", user: reply_sender)
        reply_email = raw_email.gsub("<test123@example.com>", "<reply123@example.com>")
        reply_email = reply_email.gsub("Subject: Test Subject", "Subject: Re: Test Subject\nIn-Reply-To: <test123@example.com>")
        allow_any_instance_of(described_class).to receive(:build_from_aliases).and_return([ reply_sender_alias ])

        reply_message = nil
        # Activities created for user1 and user2 (not reply_sender since they're the sender)
        expect {
          reply_message = ingestor.ingest_raw(reply_email)
        }.to change { Activity.where(activity_type: "topic_message_received").count }.by(2)

        activities = Activity.where(activity_type: "topic_message_received", subject: reply_message)
        expect(activities.pluck(:user_id)).to match_array([ user1.id, user2.id ])
      end

      it "does not create activity for the sender even if they starred the topic" do
        sender_alias = create(:alias, email: "sender@example.com", user: user1)
        allow_any_instance_of(described_class).to receive(:build_from_aliases).and_return([ sender_alias ])

        first_message = ingestor.ingest_raw(raw_email)
        topic = first_message.topic

        create(:topic_star, user: user2, topic: topic)

        reply_email = raw_email.gsub("<test123@example.com>", "<reply456@example.com>")
        reply_email = reply_email.gsub("Subject: Test Subject", "Subject: Re: Test Subject\nIn-Reply-To: <test123@example.com>")

        # user1 is the sender of the reply (build_from_aliases still returns sender_alias)
        reply_message = ingestor.ingest_raw(reply_email)

        # Sender (user1) should not get an activity
        sender_activity = Activity.find_by(user: user1, activity_type: "topic_message_received", subject: reply_message)
        expect(sender_activity).to be_nil

        # Other starred user (user2) should get an unread activity
        other_activity = Activity.find_by(user: user2, activity_type: "topic_message_received", subject: reply_message)
        expect(other_activity).to be_present
        expect(other_activity.read_at).to be_nil
      end

      it "includes correct payload in activities" do
        sender_alias = create(:alias, email: "sender@example.com", name: "Test Sender", user: user1)
        allow_any_instance_of(described_class).to receive(:build_from_aliases).and_return([ sender_alias ])

        first_message = ingestor.ingest_raw(raw_email)
        topic = first_message.topic

        create(:topic_star, user: user2, topic: topic)

        reply_sender_alias = create(:alias, email: "replier@example.com", name: "Reply Sender")
        reply_email = raw_email.gsub("<test123@example.com>", "<reply789@example.com>")
        reply_email = reply_email.gsub("Subject: Test Subject", "Subject: Re: Test Subject\nIn-Reply-To: <test123@example.com>")
        allow_any_instance_of(described_class).to receive(:build_from_aliases).and_return([ reply_sender_alias ])

        reply_message = ingestor.ingest_raw(reply_email)

        activity = Activity.find_by(user: user2, subject: reply_message)
        expect(activity.payload).to eq({
          "topic_id" => topic.id,
          "message_id" => reply_message.id
        })
      end
    end
  end
end
