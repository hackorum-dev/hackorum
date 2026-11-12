require 'rails_helper'

RSpec.describe Message, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:topic) }
    it { is_expected.to belong_to(:sender).class_name('Alias') }
    it { is_expected.to belong_to(:reply_to).class_name('Message').optional }
    it { is_expected.to have_many(:replies).class_name('Message') }
    it { is_expected.to have_many(:attachments) }
    it { is_expected.to have_many(:mentions) }
    it { is_expected.to have_many(:mentioned_aliases).through(:mentions) }
  end

  describe "validations" do
    subject { build(:message) }

    it "is valid with valid attributes" do
      expect(subject).to be_valid
    end

    it "requires a subject" do
      subject.subject = nil
      expect(subject).not_to be_valid
    end

    it "allows blank body for imports" do
      subject.body = nil
      expect(subject).to be_valid
    end
  end

  describe "threading" do
    let(:topic) { create(:topic) }
    let(:root_message) { create(:message, topic: topic, reply_to: nil) }
    let(:reply) { create(:message, topic: topic, reply_to: root_message) }

    it "can be a root message" do
      expect(root_message.reply_to).to be_nil
    end

    it "can be a reply to another message" do
      expect(reply.reply_to).to eq(root_message)
      expect(root_message.replies).to include(reply)
    end
  end

  describe "factory" do
    it "creates a valid message" do
      message = create(:message)
      expect(message).to be_persisted
      expect(message.subject).to be_present
      expect(message.body).to be_present
      expect(message.sender).to be_present
      expect(message.topic).to be_present
    end

    it "creates a root message" do
      message = create(:message, :root_message)
      expect(message.reply_to).to be_nil
    end

    it "creates a message with attachments" do
      message = create(:message, :with_attachments)
      expect(message.attachments.count).to eq(2)
    end
  end

  describe 'is_patch_submission' do
    let(:message) { create(:message) }

    it 'defaults to false' do
      expect(message.is_patch_submission).to eq(false)
    end

    it 'flips to true when a patch attachment is added' do
      create(:attachment, :patch_file, message: message, file_name: "0001-feature.patch")
      expect(message.reload.is_patch_submission).to eq(true)
    end

    it 'recognizes .patch.gz as a patch submission' do
      create(:attachment, message: message, file_name: "0001-feature.patch.gz", content_type: "application/gzip")
      expect(message.reload.is_patch_submission).to eq(true)
    end

    it 'recognizes .diffs as a patch submission' do
      create(:attachment, message: message, file_name: "regression.diffs")
      expect(message.reload.is_patch_submission).to eq(true)
    end

    it 'recognizes .patch.txt as a patch submission' do
      create(:attachment, message: message, file_name: "fix.patch.txt")
      expect(message.reload.is_patch_submission).to eq(true)
    end

    it 'recognizes .diff.bz2 as a patch submission' do
      create(:attachment, message: message, file_name: "0001.diff.bz2", content_type: "application/x-bzip2")
      expect(message.reload.is_patch_submission).to eq(true)
    end

    it 'ignores attachments with nocfbot in the name' do
      create(:attachment, message: message, file_name: "0001-nocfbot.patch")
      expect(message.reload.is_patch_submission).to eq(false)
    end

    it 'ignores attachments with no_cfbot in the name' do
      create(:attachment, message: message, file_name: "0001-no_cfbot.patch")
      expect(message.reload.is_patch_submission).to eq(false)
    end

    it 'is true if at least one attachment qualifies even when others are excluded' do
      create(:attachment, message: message, file_name: "0001-nocfbot.patch")
      create(:attachment, message: message, file_name: "0002-real.patch")
      expect(message.reload.is_patch_submission).to eq(true)
    end

    it 'flips back to false when the last patch is destroyed' do
      attachment = create(:attachment, :patch_file, message: message, file_name: "0001-feature.patch")
      expect(message.reload.is_patch_submission).to eq(true)
      attachment.destroy!
      expect(message.reload.is_patch_submission).to eq(false)
    end

    it 'ignores content-based patches without a patch extension' do
      create(:attachment, :content_based_patch, message: message)
      expect(message.reload.is_patch_submission).to eq(false)
    end

    it 'recognizes text/x-diff content type even when filename has no patch extension' do
      create(:attachment, message: message, file_name: "0001-f.txt", content_type: "text/x-diff; charset=us-ascii")
      expect(message.reload.is_patch_submission).to eq(true)
    end

    it 'recognizes bare "diff" basename with path prefix' do
      create(:attachment, message: message, file_name: "/bjm/diff", content_type: "text/plain")
      expect(message.reload.is_patch_submission).to eq(true)
    end

    it 'recognizes bare "patch" basename' do
      create(:attachment, message: message, file_name: "patch", content_type: "text/plain; charset=us-ascii")
      expect(message.reload.is_patch_submission).to eq(true)
    end

    it 'recognizes numeric-suffixed patch like .patch.3' do
      create(:attachment, message: message, file_name: "pgsql-6.2.1.alpha.patch.3", content_type: "text/plain")
      expect(message.reload.is_patch_submission).to eq(true)
    end

    it 'still excludes nocfbot names even with text/x-diff content type' do
      create(:attachment, message: message, file_name: "nocfbot.diff", content_type: "text/x-diff")
      expect(message.reload.is_patch_submission).to eq(false)
    end

    it 'does not flag arbitrary filenames ending in "patch" without a separator' do
      create(:attachment, message: message, file_name: "mypatch", content_type: "text/plain")
      expect(message.reload.is_patch_submission).to eq(false)
    end
  end

  describe 'state' do
    it 'defaults to sent' do
      expect(create(:message).state).to eq('sent')
    end

    it 'has helper predicates' do
      msg = build(:message, state: 'pending')
      expect(msg).to be_pending
      expect(msg).not_to be_sent
    end

    it 'scopes pending and sent' do
      sent = create(:message, state: 'sent')
      pending = create(:message, state: 'pending')
      expect(Message.pending).to include(pending)
      expect(Message.pending).not_to include(sent)
      expect(Message.sent).to include(sent)
      expect(Message.sent).not_to include(pending)
    end
  end
  describe "patchset feed event" do
    let(:message) { create(:message) }

    def posted
      FeedEvent.where(event_type: "patchset.posted", message_id: message.id)
    end

    it "is recorded when the first patch attachment arrives, once" do
      create(:attachment, message: message, file_name: "notes.txt", content_type: "text/plain")
      expect(posted.count).to eq(0)

      create(:attachment, message: message, file_name: "0001-x.patch")
      create(:attachment, message: message, file_name: "0002-y.patch")

      expect(posted.count).to eq(1)
      expect(posted.sole.occurred_at).to eq(message.reload.created_at)
    end

    it "is not repeated when the flag goes away and comes back" do
      attachment = create(:attachment, message: message, file_name: "0001-x.patch")
      first_id = posted.sole.id
      attachment.destroy!
      expect(message.reload.is_patch_submission).to be(false)

      create(:attachment, message: message, file_name: "0001-x.patch")

      expect(message.reload.is_patch_submission).to be(true)
      expect(posted.pluck(:id)).to eq([ first_id ])
    end

    it "does not stop the attachment from saving when the recorder fails" do
      allow(FeedEvent).to receive(:insert_all).and_raise(ActiveRecord::StatementInvalid, "boom")
      allow(Rails.logger).to receive(:warn)

      create(:attachment, message: message, file_name: "0001-x.patch")

      expect(message.reload.is_patch_submission).to be(true)
      expect(Rails.logger).to have_received(:warn).with(/patchset\.posted/)
    end
  end
end
