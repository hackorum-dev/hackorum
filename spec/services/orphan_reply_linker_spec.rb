require "rails_helper"

RSpec.describe OrphanReplyLinker do
  let(:list) { create(:mailing_list) }
  let(:ingestor) { EmailIngestor.new }

  def raw(id:, subject:, in_reply_to: nil, references: nil, date: Time.current)
    headers = [
      "From: Sender <sender@example.com>",
      "To: list@example.com",
      "Subject: #{subject}",
      "Message-ID: <#{id}>",
      "Date: #{date.rfc2822}"
    ]
    headers << "In-Reply-To: <#{in_reply_to}>" if in_reply_to
    headers << "References: #{references.map { |r| "<#{r}>" }.join(' ')}" if references
    headers.join("\n") + "\n\nBody of #{id}\n"
  end

  def ingest(**args)
    ingestor.ingest_raw(raw(**args), mailing_list: list)
  end

  describe "replies ingested before their parent" do
    it "links the reply and merges its topic when the parent arrives" do
      reply = ingest(id: "b@x", subject: "Re: Thing", in_reply_to: "a@x")
      orphan_topic = reply.topic
      root = ingest(id: "a@x", subject: "Thing", date: 1.hour.ago)

      reply.reload
      expect(reply.reply_to).to eq(root)
      expect(reply.topic).to eq(root.topic)
      expect(orphan_topic.reload.merged_into_topic).to eq(root.topic)
      expect(root.topic.reload.message_count).to eq(2)
      expect(Topic.active.count).to eq(1)
    end

    it "carries the replies of the orphan along" do
      reply = ingest(id: "b@x", subject: "Re: Thing", in_reply_to: "a@x")
      nested = ingest(id: "c@x", subject: "Re: Thing", in_reply_to: "b@x")
      root = ingest(id: "a@x", subject: "Thing")

      expect(nested.reload.topic).to eq(root.topic)
      expect(nested.reply_to).to eq(reply)
    end

    it "collapses a chain ingested in reverse order" do
      c = ingest(id: "c@x", subject: "Re: Thing", in_reply_to: "b@x", references: %w[a@x b@x])
      b = ingest(id: "b@x", subject: "Re: Thing", in_reply_to: "a@x")
      a = ingest(id: "a@x", subject: "Thing")

      expect(Topic.active.to_a).to eq([ a.topic ])
      expect(a.topic.reload.message_count).to eq(3)
      expect(c.reload.reply_to).to eq(b)
      expect(b.reload.reply_to).to eq(a)
    end

    it "joins sibling replies into one topic" do
      b1 = ingest(id: "b1@x", subject: "Re: Thing", in_reply_to: "a@x")
      b2 = ingest(id: "b2@x", subject: "Re: Thing", in_reply_to: "a@x")
      a = ingest(id: "a@x", subject: "Thing")

      expect([ b1, b2 ].map { |m| m.reload.topic }).to all(eq(a.topic))
      expect(Topic.active.count).to eq(1)
    end

    it "merges into the existing thread when the late parent has a known parent" do
      a = ingest(id: "a@x", subject: "Thing")
      c = ingest(id: "c@x", subject: "Re: Thing", in_reply_to: "b@x")
      b = ingest(id: "b@x", subject: "Re: Thing", in_reply_to: "a@x")

      expect(b.topic).to eq(a.topic)
      expect(c.reload.topic).to eq(a.topic)
      expect(c.reply_to).to eq(b)
    end

    it "keeps the attachment flag of the merged topic" do
      reply = ingest(id: "b@x", subject: "Re: Thing", in_reply_to: "a@x")
      reply.topic.update_column(:has_attachments, true)
      root = ingest(id: "a@x", subject: "Thing")

      expect(root.topic.reload.has_attachments).to be(true)
    end

    it "does not build a reply cycle" do
      a = ingest(id: "a@x", subject: "Thing", in_reply_to: "b@x")
      b = ingest(id: "b@x", subject: "Re: Thing", in_reply_to: "a@x")

      expect(b.reply_to).to eq(a)
      expect(a.reload.reply_to).to be_nil
    end

    it "leaves unrelated orphans alone" do
      other = ingest(id: "z@x", subject: "Re: Other", in_reply_to: "y@x")
      ingest(id: "a@x", subject: "Thing")

      expect(other.reload.reply_to).to be_nil
      expect(Topic.active.count).to eq(2)
    end
  end

  describe ".link" do
    it "only sets the parent when both are in one topic" do
      topic = create(:topic)
      parent = create(:message, topic: topic)
      child = create(:message, topic: topic, reply_to_message_id: parent.message_id)

      expect { described_class.link(child, parent) }.not_to change(TopicMerge, :count)
      expect(child.reload.reply_to).to eq(parent)
    end
  end
end
