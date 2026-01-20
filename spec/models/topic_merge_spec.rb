require 'rails_helper'

RSpec.describe TopicMerge, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:source_topic).class_name('Topic') }
    it { is_expected.to belong_to(:target_topic).class_name('Topic') }
    it { is_expected.to belong_to(:merged_by).class_name('User').optional }
    it { is_expected.to have_many(:message_moves).dependent(:destroy) }
  end

  describe "validations" do
    let(:source_topic) { create(:topic) }
    let(:target_topic) { create(:topic) }
    let(:admin_user) { create(:user, admin: true) }

    it "is valid with valid attributes" do
      topic_merge = build(:topic_merge, source_topic: source_topic, target_topic: target_topic, merged_by: admin_user)
      expect(topic_merge).to be_valid
    end

    it "requires source and target to be different" do
      topic_merge = build(:topic_merge, source_topic: source_topic, target_topic: source_topic, merged_by: admin_user)
      expect(topic_merge).not_to be_valid
      expect(topic_merge.errors[:target_topic]).to include('cannot be the same as source topic')
    end

    it "prevents duplicate merges of the same source" do
      create(:topic_merge, source_topic: source_topic, target_topic: target_topic, merged_by: admin_user)
      duplicate = build(:topic_merge, source_topic: source_topic, target_topic: create(:topic), merged_by: admin_user)
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:source_topic_id]).to include('has already been merged')
    end

    context "when source topic is already merged" do
      before do
        source_topic.update!(merged_into_topic: create(:topic))
      end

      it "is not valid" do
        topic_merge = build(:topic_merge, source_topic: source_topic, target_topic: target_topic, merged_by: admin_user)
        expect(topic_merge).not_to be_valid
        expect(topic_merge.errors[:source_topic]).to include('has already been merged')
      end
    end

    context "when target topic is merged" do
      before do
        target_topic.update!(merged_into_topic: create(:topic))
      end

      it "is not valid" do
        topic_merge = build(:topic_merge, source_topic: source_topic, target_topic: target_topic, merged_by: admin_user)
        expect(topic_merge).not_to be_valid
        expect(topic_merge.errors[:target_topic]).to include('has been merged into another topic')
      end
    end
  end
end
