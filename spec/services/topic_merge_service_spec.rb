require "rails_helper"

RSpec.describe TopicMergeService do
  let(:admin_user) { create(:user, admin: true) }
  let(:source_topic) { create(:topic, :with_messages) }
  let(:target_topic) { create(:topic, :with_messages) }

  describe "#call" do
    subject(:service) do
      described_class.new(
        source_topic: source_topic,
        target_topic: target_topic,
        merged_by: admin_user,
        merge_reason: "Test merge"
      )
    end

    it "returns a successful result" do
      result = service.call
      expect(result.success?).to be true
      expect(result.topic_merge).to be_persisted
    end

    it "creates a TopicMerge audit record" do
      expect { service.call }.to change(TopicMerge, :count).by(1)

      topic_merge = TopicMerge.last
      expect(topic_merge.source_topic).to eq(source_topic)
      expect(topic_merge.target_topic).to eq(target_topic)
      expect(topic_merge.merged_by).to eq(admin_user)
      expect(topic_merge.merge_reason).to eq("Test merge")
    end

    it "creates MessageMove records for all source messages" do
      source_message_count = source_topic.messages.count
      expect(source_message_count).to be > 0

      service.call

      topic_merge = TopicMerge.last
      expect(topic_merge.message_moves.count).to eq(source_message_count)
    end

    it "moves all messages to the target topic" do
      original_source_count = source_topic.messages.count
      original_target_count = target_topic.messages.count

      service.call

      expect(source_topic.reload.messages.count).to eq(0)
      expect(target_topic.reload.messages.count).to eq(original_source_count + original_target_count)
    end

    it "marks the source topic as merged" do
      service.call

      source_topic.reload
      expect(source_topic.merged?).to be true
      expect(source_topic.merged_into_topic).to eq(target_topic)
    end

    it "recalculates target topic participants" do
      service.call

      target_topic.reload
      expect(target_topic.participant_count).to be > 0
      expect(target_topic.message_count).to be > 0
    end

    context "validation errors" do
      it "fails when merging topic into itself" do
        service = described_class.new(
          source_topic: source_topic,
          target_topic: source_topic,
          merged_by: admin_user
        )

        result = service.call
        expect(result.success?).to be false
        expect(result.error).to include("itself")
      end

      it "fails when source topic is already merged" do
        source_topic.update!(merged_into_topic: create(:topic))

        result = service.call
        expect(result.success?).to be false
        expect(result.error).to include("already been merged")
      end

      it "fails when target topic is merged" do
        target_topic.update!(merged_into_topic: create(:topic))

        result = service.call
        expect(result.success?).to be false
        expect(result.error).to include("merged into another")
      end

      it "fails when user is not an admin" do
        regular_user = create(:user, admin: false)
        service = described_class.new(
          source_topic: source_topic,
          target_topic: target_topic,
          merged_by: regular_user
        )

        result = service.call
        expect(result.success?).to be false
        expect(result.error).to include("admin")
      end
    end

    context "with topic stars" do
      let(:user1) { create(:user) }
      let(:user2) { create(:user) }

      before do
        create(:topic_star, user: user1, topic: source_topic)
        create(:topic_star, user: user2, topic: target_topic)
      end

      it "moves stars from source to target" do
        service.call

        expect(TopicStar.where(topic: source_topic).count).to eq(0)
        expect(TopicStar.where(topic: target_topic, user: user1).exists?).to be true
      end

      it "deduplicates stars when user starred both topics" do
        create(:topic_star, user: user1, topic: target_topic)

        service.call

        expect(TopicStar.where(topic: target_topic, user: user1).count).to eq(1)
      end
    end

    context "with notes" do
      before do
        author = create(:user)
        create(:note, topic: source_topic, author: author)
      end

      it "moves notes to target topic" do
        service.call

        expect(source_topic.notes.count).to eq(0)
        expect(target_topic.reload.notes.count).to be >= 1
      end
    end
  end

  describe "#preview" do
    subject(:service) do
      described_class.new(
        source_topic: source_topic,
        target_topic: target_topic,
        merged_by: admin_user
      )
    end

    it "returns source topic summary" do
      preview = service.preview

      expect(preview[:source][:id]).to eq(source_topic.id)
      expect(preview[:source][:title]).to eq(source_topic.title)
      expect(preview[:source][:message_count]).to eq(source_topic.message_count)
    end

    it "returns target topic summary" do
      preview = service.preview

      expect(preview[:target][:id]).to eq(target_topic.id)
      expect(preview[:target][:title]).to eq(target_topic.title)
    end

    it "returns merged result preview" do
      preview = service.preview

      expect(preview[:result][:total_message_count]).to eq(
        source_topic.message_count + target_topic.message_count
      )
    end
  end
end
