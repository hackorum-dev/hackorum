require "rails_helper"

RSpec.describe MessageMailingList, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:message) }
    it { is_expected.to belong_to(:mailing_list) }
  end

  describe "after_create callback" do
    let(:mailing_list) { create(:mailing_list) }
    let(:topic) { create(:topic) }
    let(:message) { create(:message, topic: topic) }

    it "creates a TopicMailingList for the message's topic" do
      expect {
        MessageMailingList.create!(message: message, mailing_list: mailing_list)
      }.to change { TopicMailingList.count }.by(1)

      tml = TopicMailingList.last
      expect(tml.topic).to eq(topic)
      expect(tml.mailing_list).to eq(mailing_list)
    end

    it "does not create duplicate TopicMailingList" do
      TopicMailingList.create!(topic: topic, mailing_list: mailing_list)

      expect {
        MessageMailingList.create!(message: message, mailing_list: mailing_list)
      }.not_to change { TopicMailingList.count }
    end

    it "handles multiple messages in same topic and list" do
      message2 = create(:message, topic: topic)

      MessageMailingList.create!(message: message, mailing_list: mailing_list)
      expect {
        MessageMailingList.create!(message: message2, mailing_list: mailing_list)
      }.not_to change { TopicMailingList.count }
    end
  end
end
