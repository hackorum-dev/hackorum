require 'rails_helper'

RSpec.describe MessageMove, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:topic_merge) }
    it { is_expected.to belong_to(:message) }
  end

  describe "validations" do
    let(:topic_merge) { create(:topic_merge) }
    let(:message) { create(:message, topic: topic_merge.source_topic) }

    it "is valid with valid attributes" do
      message_move = build(:message_move, topic_merge: topic_merge, message: message)
      expect(message_move).to be_valid
    end

    it "prevents duplicate message moves within the same merge" do
      create(:message_move, topic_merge: topic_merge, message: message)
      duplicate = build(:message_move, topic_merge: topic_merge, message: message)
      expect(duplicate).not_to be_valid
    end
  end

  describe "delegation" do
    let(:topic_merge) { create(:topic_merge) }
    let(:message) { create(:message, topic: topic_merge.source_topic) }
    let(:message_move) { create(:message_move, topic_merge: topic_merge, message: message) }

    it "delegates source_topic to topic_merge" do
      expect(message_move.source_topic).to eq(topic_merge.source_topic)
    end

    it "delegates target_topic to topic_merge" do
      expect(message_move.target_topic).to eq(topic_merge.target_topic)
    end
  end
end
