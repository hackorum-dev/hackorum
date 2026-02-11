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
end
