require 'rails_helper'

RSpec.describe TopicStar, type: :model do
  describe 'associations' do
    it { should belong_to(:user) }
    it { should belong_to(:topic) }
  end

  describe 'validations' do
    it 'prevents duplicate stars' do
      user = create(:user)
      topic = create(:topic)
      create(:topic_star, user: user, topic: topic)

      duplicate = build(:topic_star, user: user, topic: topic)
      expect(duplicate).not_to be_valid
    end
  end

  describe '.toggle_star' do
    let(:user) { create(:user) }
    let(:topic) { create(:topic) }

    it 'creates a star if none exists' do
      result = TopicStar.toggle_star(user: user, topic: topic)
      expect(result).to be true
      expect(TopicStar.count).to eq(1)
    end

    it 'removes a star if one exists' do
      create(:topic_star, user: user, topic: topic)
      result = TopicStar.toggle_star(user: user, topic: topic)
      expect(result).to be false
      expect(TopicStar.count).to eq(0)
    end
  end

  describe '.starred_by_user?' do
    let(:user) { create(:user) }
    let(:topic) { create(:topic) }

    it 'returns true when user has starred the topic' do
      create(:topic_star, user: user, topic: topic)
      expect(TopicStar.starred_by_user?(user: user, topic: topic)).to be true
    end

    it 'returns false when user has not starred the topic' do
      expect(TopicStar.starred_by_user?(user: user, topic: topic)).to be false
    end
  end
end
