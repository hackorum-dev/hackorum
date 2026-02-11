require 'rails_helper'

RSpec.describe Topic, type: :model do
  describe "associations" do
    it { is_expected.to belong_to(:creator).class_name('Alias') }
    it { is_expected.to have_many(:messages) }
    it { is_expected.to have_many(:attachments).through(:messages) }
  end

  describe "validations" do
    subject { build(:topic) }

    it "is valid with valid attributes" do
      expect(subject).to be_valid
    end

    it "requires a title" do
      subject.title = nil
      expect(subject).not_to be_valid
    end

    it "requires a creator" do
      subject.creator = nil
      expect(subject).not_to be_valid
    end
  end

  describe "factory" do
    it "creates a valid topic" do
      topic = create(:topic)
      expect(topic).to be_persisted
      expect(topic.title).to be_present
      expect(topic.creator).to be_present
    end

    it "creates a topic with messages" do
      topic = create(:topic, :with_messages)
      expect(topic.messages.count).to eq(3)
    end
  end

  describe "merge functionality" do
    describe "#merged?" do
      it "returns false for active topics" do
        topic = create(:topic)
        expect(topic.merged?).to be false
      end

      it "returns true for merged topics" do
        target = create(:topic)
        topic = create(:topic, merged_into_topic: target)
        expect(topic.merged?).to be true
      end
    end

    describe "#final_topic" do
      it "returns self for active topics" do
        topic = create(:topic)
        expect(topic.final_topic).to eq(topic)
      end

      it "returns the merge target for merged topics" do
        target = create(:topic)
        topic = create(:topic, merged_into_topic: target)
        expect(topic.final_topic).to eq(target)
      end

      it "follows merge chains" do
        final_target = create(:topic)
        intermediate = create(:topic, merged_into_topic: final_target)
        topic = create(:topic, merged_into_topic: intermediate)

        expect(topic.final_topic).to eq(final_target)
      end
    end

    describe ".normalize_title" do
      it "removes Re: prefix" do
        expect(Topic.normalize_title("Re: Some subject")).to eq("Some subject")
      end

      it "removes Fwd: prefix" do
        expect(Topic.normalize_title("Fwd: Some subject")).to eq("Some subject")
      end

      it "removes Fw: prefix" do
        expect(Topic.normalize_title("Fw: Some subject")).to eq("Some subject")
      end

      it "normalizes whitespace" do
        expect(Topic.normalize_title("  Subject  with   spaces  ")).to eq("Subject with spaces")
      end
    end

    describe ".suggest_merge_targets" do
      it "suggests topics with similar titles" do
        target = create(:topic, title: "PostgreSQL Performance Tuning")
        source = create(:topic, title: "Re: PostgreSQL Performance Tuning")

        suggestions = Topic.suggest_merge_targets(source)
        expect(suggestions).to include(target)
      end

      it "excludes the source topic from suggestions" do
        source = create(:topic, title: "PostgreSQL Performance Tuning")

        suggestions = Topic.suggest_merge_targets(source)
        expect(suggestions).not_to include(source)
      end

      it "excludes merged topics" do
        merged_topic = create(:topic, title: "PostgreSQL Performance Tuning", merged_into_topic: create(:topic))
        source = create(:topic, title: "Re: PostgreSQL Performance Tuning")

        suggestions = Topic.suggest_merge_targets(source)
        expect(suggestions).not_to include(merged_topic)
      end
    end

    describe "scopes" do
      it "active scope excludes merged topics" do
        active_topic = create(:topic)
        merged_topic = create(:topic, merged_into_topic: active_topic)

        expect(Topic.active).to include(active_topic)
        expect(Topic.active).not_to include(merged_topic)
      end

      it "merged scope includes only merged topics" do
        active_topic = create(:topic)
        merged_topic = create(:topic, merged_into_topic: active_topic)

        expect(Topic.merged).not_to include(active_topic)
        expect(Topic.merged).to include(merged_topic)
      end
    end
  end
end
