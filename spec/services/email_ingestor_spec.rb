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
    let(:mailing_list) { create(:mailing_list) }
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
          ingestor.ingest_raw(raw_email, mailing_list: mailing_list)
        }.to change { TopicStar.count }.by(1)

        star = TopicStar.last
        expect(star.user).to eq(user1)
        expect(star.topic).to be_present
      end

      it "does not create star for guest sender" do
        guest_alias = create(:alias, email: "sender@example.com", user: nil)
        allow_any_instance_of(described_class).to receive(:build_from_aliases).and_return([ guest_alias ])

        expect {
          ingestor.ingest_raw(raw_email, mailing_list: mailing_list)
        }.not_to change { TopicStar.count }
      end

      it "is idempotent - handles existing stars" do
        sender_alias = create(:alias, email: "sender@example.com", user: user1)
        allow_any_instance_of(described_class).to receive(:build_from_aliases).and_return([ sender_alias ])

        first_message = ingestor.ingest_raw(raw_email, mailing_list: mailing_list)
        expect(TopicStar.count).to eq(1)

        reply_email = raw_email.gsub("<test123@example.com>", "<test456@example.com>")
        reply_email = reply_email.gsub("Subject: Test Subject", "Subject: Re: Test Subject\nIn-Reply-To: <test123@example.com>")

        expect {
          ingestor.ingest_raw(reply_email, mailing_list: mailing_list)
        }.not_to change { TopicStar.count }

        expect(TopicStar.where(user: user1, topic: first_message.topic).count).to eq(1)
      end
    end

    context "activity creation" do
      it "creates activities for users who have starred the topic (excluding sender)" do
        sender_alias = create(:alias, email: "sender@example.com", user: user1)
        allow_any_instance_of(described_class).to receive(:build_from_aliases).and_return([ sender_alias ])

        first_message = ingestor.ingest_raw(raw_email, mailing_list: mailing_list)
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
          reply_message = ingestor.ingest_raw(reply_email, mailing_list: mailing_list)
        }.to change { Activity.where(activity_type: "topic_message_received").count }.by(2)

        activities = Activity.where(activity_type: "topic_message_received", subject: reply_message)
        expect(activities.pluck(:user_id)).to match_array([ user1.id, user2.id ])
      end

      it "does not create activity for the sender even if they starred the topic" do
        sender_alias = create(:alias, email: "sender@example.com", user: user1)
        allow_any_instance_of(described_class).to receive(:build_from_aliases).and_return([ sender_alias ])

        first_message = ingestor.ingest_raw(raw_email, mailing_list: mailing_list)
        topic = first_message.topic

        create(:topic_star, user: user2, topic: topic)

        reply_email = raw_email.gsub("<test123@example.com>", "<reply456@example.com>")
        reply_email = reply_email.gsub("Subject: Test Subject", "Subject: Re: Test Subject\nIn-Reply-To: <test123@example.com>")

        # user1 is the sender of the reply (build_from_aliases still returns sender_alias)
        reply_message = ingestor.ingest_raw(reply_email, mailing_list: mailing_list)

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

        first_message = ingestor.ingest_raw(raw_email, mailing_list: mailing_list)
        topic = first_message.topic

        create(:topic_star, user: user2, topic: topic)

        reply_sender_alias = create(:alias, email: "replier@example.com", name: "Reply Sender")
        reply_email = raw_email.gsub("<test123@example.com>", "<reply789@example.com>")
        reply_email = reply_email.gsub("Subject: Test Subject", "Subject: Re: Test Subject\nIn-Reply-To: <test123@example.com>")
        allow_any_instance_of(described_class).to receive(:build_from_aliases).and_return([ reply_sender_alias ])

        reply_message = ingestor.ingest_raw(reply_email, mailing_list: mailing_list)

        activity = Activity.find_by(user: user2, subject: reply_message)
        expect(activity.payload).to eq({
          "topic_id" => topic.id,
          "message_id" => reply_message.id
        })
      end
    end
  end

  describe "#ingest_raw mailing list association" do
    let(:ingestor) { described_class.new }
    let(:mailing_list) { create(:mailing_list, identifier: "pgsql-hackers", display_name: "hackers") }
    let(:other_list) { create(:mailing_list, identifier: "pgsql-bugs", display_name: "bugs") }

    let(:raw_email) do
      <<~EMAIL
        From: sender@example.com
        To: recipient@example.com
        Subject: Test Subject
        Message-ID: <list-test-123@example.com>
        Date: #{Time.current.rfc2822}

        This is the email body.
      EMAIL
    end

    it "creates MessageMailingList for new message" do
      msg = ingestor.ingest_raw(raw_email, mailing_list: mailing_list)
      expect(msg.mailing_lists).to include(mailing_list)
    end

    it "creates TopicMailingList via callback" do
      msg = ingestor.ingest_raw(raw_email, mailing_list: mailing_list)
      expect(msg.topic.mailing_lists).to include(mailing_list)
    end

    it "adds list association to existing message without updating it" do
      msg = ingestor.ingest_raw(raw_email, mailing_list: mailing_list)
      original_body = msg.body

      msg2 = ingestor.ingest_raw(raw_email, mailing_list: other_list)
      expect(msg2.id).to eq(msg.id)
      expect(msg2.body).to eq(original_body)
      expect(msg2.mailing_lists).to include(mailing_list, other_list)
    end

    it "does not duplicate list association on re-import" do
      ingestor.ingest_raw(raw_email, mailing_list: mailing_list)
      expect {
        ingestor.ingest_raw(raw_email, mailing_list: mailing_list)
      }.not_to change { MessageMailingList.count }
    end
  end

  describe "pending message echo" do
    let(:user)   { create(:user) }
    let(:sender) { create(:alias, user: user, email: "sender@example.com", name: "Sender") }
    let(:list)   { create(:mailing_list) }
    let(:topic)  { create(:topic, creator: sender) }
    let!(:pending) {
      Message.create!(
        topic: topic, sender: sender, sender_person_id: sender.person_id,
        subject: "Re: hi", body: "sent body",
        message_id: "echo-test-1@hackorum.local",
        state: Message::STATE_PENDING,
        sent_at: 1.minute.ago,
        created_at: 1.minute.ago
      )
    }

    let(:raw_echo) {
      <<~EML
        From: Sender <sender@example.com>
        To: pgsql-test@example.com
        Subject: Re: hi
        Message-ID: <echo-test-1@hackorum.local>
        Date: #{Time.current.rfc2822}

        sent body
      EML
    }

    it "flips pending to sent" do
      described_class.new.ingest_raw(raw_echo, mailing_list: list)
      expect(pending.reload.state).to eq(Message::STATE_SENT)
    end

    it "attaches the list via the existing association path" do
      described_class.new.ingest_raw(raw_echo, mailing_list: list)
      expect(pending.message_mailing_lists.where(mailing_list: list)).to exist
    end

    it "does not double-count topic.message_count" do
      initial = topic.reload.message_count
      described_class.new.ingest_raw(raw_echo, mailing_list: list)
      expect(topic.reload.message_count).to eq(initial)
    end

    it "does not change state for already-sent rows" do
      pending.update_columns(state: Message::STATE_SENT)
      described_class.new.ingest_raw(raw_echo, mailing_list: list)
      expect(pending.reload.state).to eq(Message::STATE_SENT)
    end
  end

  describe "pending echo with Gmail-rewritten Message-ID" do
    let(:user)   { create(:user) }
    let(:sender) { create(:alias, user: user, email: "sender@example.com", name: "Sender") }
    let(:list)   { create(:mailing_list) }
    let(:parent_id) { "parent-thread@example.com" }
    let(:topic)  { create(:topic, creator: sender) }
    let!(:parent_msg) {
      Message.create!(
        topic: topic, sender: sender, sender_person_id: sender.person_id,
        subject: "Topic", body: "parent body",
        message_id: parent_id, state: Message::STATE_SENT,
        created_at: 1.hour.ago
      )
    }
    let(:pending_body) { "Hello, this is my reply body with enough length to match." }
    let!(:pending) {
      Message.create!(
        topic: topic, sender: sender, sender_person_id: sender.person_id,
        reply_to: parent_msg, reply_to_message_id: parent_id,
        subject: "Re: Topic", body: pending_body,
        message_id: "<placeholder-uuid@hackorum.dev>",
        state: Message::STATE_PENDING,
        sent_at: 30.seconds.ago,
        created_at: 30.seconds.ago
      )
    }

    let(:gmail_echo_id) { "CABx_real_gmail_id@mail.gmail.com" }
    let(:echo_body) { "#{pending_body}\n\n-- \nList footer goes here" }
    let(:raw_echo) {
      <<~EML
        From: Sender <sender@example.com>
        To: pgsql-test@example.com
        Subject: [PGSQL] Re: Topic
        Message-ID: <#{gmail_echo_id}>
        In-Reply-To: <#{parent_id}>
        References: <#{parent_id}>
        Date: #{Time.current.rfc2822}

        #{echo_body}
      EML
    }

    it "flips pending to sent and rewrites message_id" do
      described_class.new.ingest_raw(raw_echo, mailing_list: list)
      pending.reload
      expect(pending.state).to eq(Message::STATE_SENT)
      expect(pending.message_id).to eq(gmail_echo_id)
    end

    it "does not create a duplicate message" do
      expect {
        described_class.new.ingest_raw(raw_echo, mailing_list: list)
      }.not_to change { Message.count }
    end

    it "associates the mailing list with the pending row" do
      described_class.new.ingest_raw(raw_echo, mailing_list: list)
      expect(pending.message_mailing_lists.where(mailing_list: list)).to exist
    end

    it "leaves pending intact when echo body does not contain pending body" do
      raw = raw_echo.sub(echo_body, "completely unrelated content here that is long enough")
      expect {
        described_class.new.ingest_raw(raw, mailing_list: list)
      }.to change { Message.count }.by(1)
      expect(pending.reload.state).to eq(Message::STATE_PENDING)
    end

    it "skips heuristic when sender email differs" do
      raw = raw_echo.sub("sender@example.com", "someone-else@example.com")
      expect {
        described_class.new.ingest_raw(raw, mailing_list: list)
      }.to change { Message.count }.by(1)
      expect(pending.reload.state).to eq(Message::STATE_PENDING)
    end

    it "skips heuristic outside the time window" do
      pending.update_columns(sent_at: 3.days.ago, created_at: 3.days.ago)
      expect {
        described_class.new.ingest_raw(raw_echo, mailing_list: list)
      }.to change { Message.count }.by(1)
      expect(pending.reload.state).to eq(Message::STATE_PENDING)
    end

    it "skips heuristic when two pending rows match ambiguously" do
      Message.create!(
        topic: topic, sender: sender, sender_person_id: sender.person_id,
        reply_to: parent_msg, reply_to_message_id: parent_id,
        subject: "Re: Topic", body: pending_body,
        message_id: "<another-placeholder@hackorum.dev>",
        state: Message::STATE_PENDING,
        sent_at: 20.seconds.ago,
        created_at: 20.seconds.ago
      )
      expect {
        described_class.new.ingest_raw(raw_echo, mailing_list: list)
      }.to change { Message.count }.by(1)
      expect(pending.reload.state).to eq(Message::STATE_PENDING)
    end

    context "with a short body and attachments" do
      let(:pending_body) { "v3 attached." }
      let(:echo_file_name) { "v3-0001-fix.patch" }
      let(:raw_echo) {
        <<~EML
          From: Sender <sender@example.com>
          To: pgsql-test@example.com
          Subject: [PGSQL] Re: Topic
          Message-ID: <#{gmail_echo_id}>
          In-Reply-To: <#{parent_id}>
          References: <#{parent_id}>
          Date: #{Time.current.rfc2822}
          MIME-Version: 1.0
          Content-Type: multipart/mixed; boundary="b"

          --b
          Content-Type: text/plain; charset=UTF-8

          #{pending_body}

          --b
          Content-Type: text/x-patch; charset=US-ASCII
          Content-Disposition: attachment; filename="#{echo_file_name}"

          diff --git a/x b/x
          --b--
        EML
      }

      before { create(:attachment, message: pending, file_name: "v3-0001-fix.patch") }

      it "matches on attachment names" do
        expect {
          described_class.new.ingest_raw(raw_echo, mailing_list: list)
        }.not_to change { [ Message.count, Attachment.count ] }
        expect(pending.reload.message_id).to eq(gmail_echo_id)
      end

      context "when the pending body is empty" do
        let(:pending_body) { "" }

        it "matches on attachment names" do
          expect {
            described_class.new.ingest_raw(raw_echo, mailing_list: list)
          }.not_to change { Message.count }
          expect(pending.reload.message_id).to eq(gmail_echo_id)
        end
      end

      context "when attachment names differ" do
        let(:echo_file_name) { "v4-0001-fix.patch" }

        it "does not match" do
          expect {
            described_class.new.ingest_raw(raw_echo, mailing_list: list)
          }.to change { Message.count }.by(1)
          expect(pending.reload.state).to eq(Message::STATE_PENDING)
        end
      end
    end
  end

  describe "#fallback_thread_lookup scoped to list" do
    let(:ingestor) { described_class.new }
    let(:hackers_list) { create(:mailing_list, identifier: "pgsql-hackers", display_name: "hackers") }
    let(:bugs_list) { create(:mailing_list, identifier: "pgsql-bugs", display_name: "bugs") }

    let!(:hackers_topic) { create(:topic) }
    let!(:hackers_msg) do
      msg = create(:message, topic: hackers_topic, subject: "Parallel query plans", created_at: 2.days.ago)
      MessageMailingList.create!(message: msg, mailing_list: hackers_list)
      msg
    end

    let!(:bugs_topic) { create(:topic) }
    let!(:bugs_msg) do
      msg = create(:message, topic: bugs_topic, subject: "Parallel query plans", created_at: 2.days.ago)
      MessageMailingList.create!(message: msg, mailing_list: bugs_list)
      msg
    end

    it "only matches messages from the same list" do
      found = ingestor.send(:fallback_thread_lookup, "Re: Parallel query plans",
        message_id: nil, references: [], sent_at: Time.current, mailing_list: bugs_list)
      expect(found).to eq(bugs_msg)
    end
  end

  describe "#ingest_raw patch paths" do
    let(:ingestor) { described_class.new }
    let(:mailing_list) { create(:mailing_list) }

    def raw_email(body, message_id: "inline-diff-1@example.com")
      <<~EMAIL
        From: sender@example.com
        To: recipient@example.com
        Subject: Inline patch
        Message-ID: <#{message_id}>
        Date: #{Time.current.rfc2822}

        #{body}
      EMAIL
    end

    it "populates patch_submission_files for inline-diff messages with no attachments" do
      body = "Here is a patch:\n\n--- a/src/inline.c\n+++ b/src/inline.c\n@@ -1 +1 @@\n-old\n+new\n"
      msg = ingestor.ingest_raw(raw_email(body), mailing_list: mailing_list)

      expect(msg.attachments).to be_empty
      expect(msg.patch_submission_files.pluck(:path)).to eq([ "src/inline.c" ])
    end

    it "recomputes patch paths when re-import updates the body" do
      msg = ingestor.ingest_raw(raw_email("plain text body"), mailing_list: mailing_list)
      expect(msg.patch_submission_files).to be_empty

      new_body = "--- a/src/two.c\n+++ b/src/two.c\n@@ -1 +1 @@\n"
      ingestor.ingest_raw(raw_email(new_body), mailing_list: mailing_list, update_existing: [ :body ])

      expect(msg.reload.patch_submission_files.pluck(:path)).to eq([ "src/two.c" ])
    end
  end

  describe "#ingest_raw date correction" do
    let(:ingestor) { described_class.new }
    let(:mailing_list) { create(:mailing_list) }

    def raw_email_at(sent_at, message_id:)
      <<~EMAIL
        From: sender@example.com
        To: recipient@example.com
        Subject: Dated mail
        Message-ID: <#{message_id}>
        Date: #{sent_at.rfc2822}

        body text
      EMAIL
    end

    it "resyncs the topic's cached last message when a corrected date moves it later" do
      original = Time.zone.parse("2026-01-10 12:00:00")
      msg = ingestor.ingest_raw(raw_email_at(original, message_id: "date-fix-1@example.com"),
                                mailing_list: mailing_list)
      topic = msg.topic
      expect(topic.reload.last_message_at).to be_within(1.second).of(original)

      corrected = Time.zone.parse("2026-02-20 08:30:00")
      ingestor.ingest_raw(raw_email_at(corrected, message_id: "date-fix-1@example.com"),
                          mailing_list: mailing_list, update_existing: [ :date ])

      expect(msg.reload.created_at).to be_within(1.second).of(corrected)
      expect(topic.reload.last_message_at).to be_within(1.second).of(corrected)
      expect(topic.last_message_id).to eq(msg.id)
    end

    it "resyncs when the corrected date moves the message earlier" do
      original = Time.zone.parse("2026-03-15 09:00:00")
      msg = ingestor.ingest_raw(raw_email_at(original, message_id: "date-fix-2@example.com"),
                                mailing_list: mailing_list)
      topic = msg.topic

      corrected = Time.zone.parse("2026-01-05 07:15:00")
      ingestor.ingest_raw(raw_email_at(corrected, message_id: "date-fix-2@example.com"),
                          mailing_list: mailing_list, update_existing: [ :date ])

      expect(topic.reload.last_message_at).to be_within(1.second).of(corrected)
    end

    it "resyncs the sender's participant timestamps" do
      original = Time.zone.parse("2026-01-10 12:00:00")
      msg = ingestor.ingest_raw(raw_email_at(original, message_id: "date-fix-3@example.com"),
                                mailing_list: mailing_list)
      participant = TopicParticipant.find_by!(topic_id: msg.topic_id,
                                              person_id: msg.sender_person_id)

      corrected = Time.zone.parse("2026-02-20 08:30:00")
      ingestor.ingest_raw(raw_email_at(corrected, message_id: "date-fix-3@example.com"),
                          mailing_list: mailing_list, update_existing: [ :date ])

      participant.reload
      expect(participant.last_message_at).to be_within(1.second).of(corrected)
      expect(participant.first_message_at).to be_within(1.second).of(corrected)
    end

    it "leaves cached timestamps alone when the date is unchanged" do
      sent_at = Time.zone.parse("2026-01-10 12:00:00")
      msg = ingestor.ingest_raw(raw_email_at(sent_at, message_id: "date-fix-4@example.com"),
                                mailing_list: mailing_list)
      topic = msg.topic
      before = topic.reload.last_message_at

      ingestor.ingest_raw(raw_email_at(sent_at, message_id: "date-fix-4@example.com"),
                          mailing_list: mailing_list, update_existing: [ :date ])

      expect(topic.reload.last_message_at).to eq(before)
    end
  end

  describe "#ingest_raw header edge cases" do
    let(:list) { create(:mailing_list) }
    let(:ingestor) { described_class.new }

    def raw(headers, body = "hello\n")
      "From: Alice <alice@example.com>\nTo: list@example.com\nSubject: Topic\n#{headers}\n\n#{body}"
    end

    it "threads multi-id and prose In-Reply-To headers" do
      parent = ingestor.ingest_raw(raw("Message-ID: <p1@x>"), mailing_list: list)
      a = ingestor.ingest_raw(raw("Message-ID: <c1@x>\nIn-Reply-To: <zz@x> <p1@x>"), mailing_list: list)
      b = ingestor.ingest_raw(raw("Message-ID: <c2@x>\nIn-Reply-To: Your message of Mon <p1@x>"), mailing_list: list)

      expect(a.reply_to_message_id).to eq("p1@x")
      expect(b.reply_to).to eq(parent)
    end

    it "uses the nearest known reference" do
      root = ingestor.ingest_raw(raw("Message-ID: <r@x>"), mailing_list: list)
      mid = ingestor.ingest_raw(raw("Message-ID: <m@x>\nIn-Reply-To: <r@x>"), mailing_list: list)
      leaf = ingestor.ingest_raw(raw("Message-ID: <l@x>\nReferences: <r@x> <m@x>"), mailing_list: list)

      expect(leaf.reply_to).to eq(mid)
      expect(root).to be_present
    end

    it "mentions every To and Cc address once" do
      msg = ingestor.ingest_raw(raw("Message-ID: <cc@x>\nCc: bob@example.com, carol@example.com, Alice <alice2@example.com>"), mailing_list: list)

      expect(msg.mentions.map { |m| m.alias.email }).to contain_exactly("list@example.com", "bob@example.com", "carol@example.com", "alice2@example.com")
    end

    it "falls back to the html part when there is no text part" do
      html = <<~MAIL
        Message-ID: <html@x>
        MIME-Version: 1.0
        Content-Type: multipart/alternative; boundary="b"

        --b
        Content-Type: text/html; charset=UTF-8

        <p>Hello <b>world</b></p>
        --b--
      MAIL
      msg = ingestor.ingest_raw(raw(html.chomp, ""), mailing_list: list)

      expect(msg.body).to include("Hello world")
    end

    it "strips NUL from encoded subjects" do
      msg = ingestor.ingest_raw(raw("Message-ID: <nul@x>").sub("Subject: Topic", "Subject: =?UTF-8?Q?hi=00there?="), mailing_list: list)

      expect(msg.subject).to eq("hithere")
    end

    it "does not crash on an unparseable trusted Date" do
      msg = ingestor.ingest_raw(raw("Message-ID: <date@x>\nDate: Mon, 32 Foo 2024 99:99:99"), mailing_list: list, trust_date: true)

      expect(msg).to be_persisted
    end
  end
end
