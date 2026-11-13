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

    it "copies the source mailing lists to the target" do
      list = create(:mailing_list)
      TopicMailingList.create!(topic: source_topic, mailing_list: list)

      service.call

      expect(target_topic.reload.mailing_lists).to include(list)
    end

    describe "hidden_by_default" do
      def post_to(topic, list)
        MessageMailingList.create!(message: topic.messages.first, mailing_list: list)
      end

      let(:hidden_list) { create(:mailing_list, hidden_by_default: true) }
      let(:shown_list) { create(:mailing_list) }

      it "keeps a shown target shown when the source is hidden" do
        post_to(source_topic, hidden_list)
        post_to(target_topic, shown_list)

        service.call

        expect(target_topic.reload.hidden_by_default).to be(false)
      end

      it "shows a hidden target when the source is shown" do
        post_to(source_topic, shown_list)
        post_to(target_topic, hidden_list)
        expect(target_topic.reload.hidden_by_default).to be(true)

        service.call

        expect(target_topic.reload.hidden_by_default).to be(false)
      end
    end

    it "moves the source slug to a target without one" do
      source_topic.update!(slug: "my-feature")

      service.call

      expect(source_topic.reload.slug).to be_nil
      expect(target_topic.reload.slug).to eq("my-feature")
    end

    it "keeps the target slug and drops the source one" do
      source_topic.update!(slug: "src")
      target_topic.update!(slug: "dst")

      service.call

      expect(source_topic.reload.slug).to be_nil
      expect(target_topic.reload.slug).to eq("dst")
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

    context "with drafts" do
      it "moves drafts to the target topic" do
        draft = create(:outgoing_draft, topic: source_topic)

        service.call

        expect(draft.reload.topic).to eq(target_topic)
      end
    end

    context "with topic ignores" do
      let(:user) { create(:user) }

      it "moves an ignore to the target" do
        create(:topic_ignore, user: user, topic: source_topic)

        service.call

        expect(TopicIgnore.where(user: user).pluck(:topic_id)).to eq([ target_topic.id ])
      end

      it "deduplicates when both topics are ignored" do
        create(:topic_ignore, user: user, topic: source_topic)
        create(:topic_ignore, user: user, topic: target_topic)

        service.call

        expect(TopicIgnore.where(user: user).pluck(:topic_id)).to eq([ target_topic.id ])
      end

      it "drops the ignore when the user stars the target" do
        create(:topic_ignore, user: user, topic: source_topic)
        create(:topic_star, user: user, topic: target_topic)

        service.call

        expect(TopicIgnore.where(user: user)).to be_empty
      end
    end

    context "with commit links" do
      let(:commit) { create(:commit, committed_at: 2.days.ago) }

      it "moves links and refreshes the commit aggregates" do
        create(:commit_topic, commit: commit, topic: source_topic)

        service.call

        expect(CommitTopic.where(commit: commit).pluck(:topic_id)).to eq([ target_topic.id ])
        target_topic.reload
        expect(target_topic.commit_count).to eq(1)
        expect(target_topic.last_commit_at).to be_within(1.second).of(commit.committed_at)
        expect(source_topic.reload.commit_count).to eq(0)
      end

      it "keeps one link per commit, preferring the trailer one" do
        create(:commit_topic, commit: commit, topic: source_topic, source: "trailer", external_message_id: "src@x")
        create(:commit_topic, commit: commit, topic: target_topic, source: "llm", external_message_id: nil)

        service.call

        links = CommitTopic.where(commit: commit)
        expect(links.pluck(:topic_id, :source, :external_message_id)).to eq([ [ target_topic.id, "trailer", "src@x" ] ])
        expect(target_topic.reload.commit_count).to eq(1)
      end
    end

    context "with patch branches" do
      def patch_message(topic, at)
        create(:message, topic: topic, created_at: at, is_patch_submission: true)
      end

      it "moves branch rows to the target" do
        row = create(:patch_branch, topic: source_topic, message: patch_message(source_topic, 1.day.ago))

        service.call

        expect(row.reload.topic).to eq(target_topic)
      end

      it "lets the pushed newest patchset retire the other current rows" do
        old = create(:patch_branch, topic: source_topic, message: patch_message(source_topic, 3.days.ago), pushed_at: 3.days.ago)
        newest = create(:patch_branch, topic: target_topic, message: patch_message(target_topic, 1.hour.from_now), pushed_at: Time.current)

        service.call

        expect(old.reload.superseded_by).to eq(newest)
        expect(newest.reload.superseded_by).to be_nil
      end

      it "keeps both rows current while the newest patchset is unpushed" do
        old = create(:patch_branch, topic: source_topic, message: patch_message(source_topic, 3.days.ago), pushed_at: 3.days.ago)
        newest = create(:patch_branch, topic: target_topic, message: patch_message(target_topic, 1.hour.from_now), status: "failed")

        service.call

        expect([ old, newest ].map { |r| r.reload.superseded_by_id }).to eq([ nil, nil ])
      end
    end

    context "with lineage data" do
      it "moves runs, lineages, verdicts and pairs to the target" do
        run = create(:patchset_run, topic: source_topic)
        lineage = create(:patchset_lineage, patchset_run: run)
        verdict = create(:commit_verdict, patchset_run: run)
        pair = create(:patchset_pair, topic: source_topic)

        service.call

        expect([ run, lineage, verdict, pair ].map { |r| r.reload.topic_id }).to all(eq(target_topic.id))
        expect(PatchsetRun.current_for(target_topic.id)).to eq(run)
      end
    end

    context "without a user" do
      it "merges when automatic" do
        result = described_class.new(source_topic: source_topic, target_topic: target_topic,
                                     merged_by: nil, automatic: true).call

        expect(result.success?).to be true
        expect(result.topic_merge.merged_by).to be_nil
      end

      it "refuses otherwise" do
        result = described_class.new(source_topic: source_topic, target_topic: target_topic, merged_by: nil).call

        expect(result.success?).to be false
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
