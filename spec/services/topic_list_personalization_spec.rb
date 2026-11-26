require 'rails_helper'

RSpec.describe TopicListPersonalization do
  let(:user) { create(:user) }
  let(:creator) { create(:alias) }
  let!(:topic) { create(:topic, creator: creator) }
  let!(:message1) { create(:message, topic: topic, sender: creator, created_at: 2.hours.ago) }
  let!(:message2) { create(:message, topic: topic, sender: creator, created_at: 1.hour.ago) }

  def personalization(topics = [ topic ])
    described_class.new(user: user, topics: topics)
  end

  describe "#state_for" do
    it "returns :new for an untouched topic" do
      expect(personalization.state_for(topic.reload)[:status]).to eq(:new)
    end

    it "returns :reading with a read count for a partially read topic" do
      MessageReadRange.add_range(user: user, topic: topic, start_id: message1.id, end_id: message1.id)
      state = personalization.state_for(topic.reload)
      expect(state[:status]).to eq(:reading)
      expect(state[:read_count]).to eq(1)
    end

    it "returns :read for a fully read topic" do
      MessageReadRange.add_range(user: user, topic: topic, start_id: message1.id, end_id: message2.id)
      expect(personalization.state_for(topic.reload)[:status]).to eq(:read)
    end

    it "returns :aware for a topic marked aware" do
      ThreadAwareness.mark_until(user: user, topic: topic, until_message_id: message2.id)
      expect(personalization.state_for(topic.reload)[:status]).to eq(:aware)
    end

    it "returns an empty hash for a topic not in the list" do
      other = create(:topic, creator: creator)
      expect(personalization.state_for(other)).to eq({})
    end
  end

  describe "#note_count_for" do
    it "counts notes visible to the user" do
      create(:note, topic: topic, author: user)
      expect(personalization.note_count_for(topic)).to eq(1)
    end

    it "leaves out the classifier bot's notes" do
      Classify::Setup.call!
      Classify::BotNote.new(topic).write!(%w[bug])
      expect(personalization.note_count_for(topic)).to eq(0)
      create(:note, topic: topic, author: user)
      expect(personalization.note_count_for(topic)).to eq(1)
    end

    it "returns 0 without notes" do
      expect(personalization.note_count_for(topic)).to eq(0)
    end
  end

  describe "#star_data_for" do
    it "flags topics starred by the user" do
      create(:topic_star, user: user, topic: topic)
      expect(personalization.star_data_for(topic)[:starred_by_me]).to be(true)
    end

    it "defaults to not starred" do
      expect(personalization.star_data_for(topic)).to eq(starred_by_me: false, team_starrers: [])
    end
  end

  describe "#participation_for" do
    it "returns an empty hash when the user did not participate" do
      expect(personalization.participation_for(topic)).to eq({})
    end
  end

  describe "#team_readers_for" do
    it "defaults to empty" do
      expect(personalization.team_readers_for(topic)).to eq([])
    end
  end

  it "handles an empty topic list" do
    p13n = personalization([])
    expect(p13n.state_for(topic)).to eq({})
  end
end
