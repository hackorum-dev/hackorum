require "rails_helper"

RSpec.describe "Topic detail modals", type: :request do
  def link_topic(topic, commit, **attrs)
    create(:commit_topic, commit: commit, topic: topic, **attrs)
    topic.update_columns(commit_count: topic.commit_topics.count)
  end

  describe "merged topics" do
    let(:source) { create(:topic) }
    let(:target) { create(:topic) }

    before { source.update!(merged_into_topic: target) }

    %i[commits_details commitfest_details patchsets_details story].each do |action|
      it "redirects #{action} to the same action on the final topic" do
        get public_send("#{action}_topic_path", source)

        expect(response).to have_http_status(:moved_permanently)
        expect(response).to redirect_to(public_send("#{action}_topic_path", target))
      end
    end

    it "redirects participants to the final topic" do
      get participants_topic_path(source)

      expect(response).to have_http_status(:moved_permanently)
      expect(response).to redirect_to(participants_topic_path(target))
    end

    it "keeps the person and frame when redirecting participant" do
      get participant_topic_path(source, person_id: 7, frame: "topic-participants-modal")

      expect(response).to have_http_status(:moved_permanently)
      expect(response).to redirect_to(participant_topic_path(target, person_id: 7, frame: "topic-participants-modal"))
    end

    it "keeps the batch ids when redirecting message_batch" do
      get message_batch_topic_path(source, ids: "1,2")

      expect(response).to have_http_status(:moved_permanently)
      expect(response).to redirect_to(message_batch_topic_path(target, ids: "1,2"))
    end

    it "still redirects show to the topic page" do
      get topic_path(source)

      expect(response).to redirect_to(topic_path(target))
    end
  end

  describe "commits_details" do
    let(:topic) { create(:topic, :with_messages) }

    it "lists changes, branches and credits" do
      commit = create(:commit, subject: "Fix the vacuum leader race", sha: "abc123def456",
                               branches: [ "REL_18_STABLE" ], released_in: "18.5",
                               committer_name: "Alvaro Herrera", committed_at: 3.days.ago)
      commit.commit_people.create!(role: "reviewer", raw_name: "buildfarm member koel")
      link_topic(topic, commit)

      get commits_details_topic_path(topic)

      expect(response).to have_http_status(:ok)
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("turbo-frame#topic-commits-modal")["target"]).to eq("_top")
      expect(response.body).to include("Fix the vacuum leader race")
      expect(response.body).to include("https://github.com/postgres/postgres/commit/abc123def456")
      expect(response.body).to include("REL_18_STABLE").and include("18.5").and include("Alvaro Herrera")
      expect(response.body).to include("buildfarm member koel")
    end

    it "collapses a backport into one entry" do
      canonical = create(:commit, sha: "aaa1", subject: "Shared change", branches: [ "master" ], committed_at: 2.days.ago)
      backport = create(:commit, sha: "bbb2", subject: "Shared change", branches: [ "REL_18_STABLE" ],
                                 cherry_picked_from_sha: "aaa1", committed_at: 1.day.ago)
      link_topic(topic, canonical)
      link_topic(topic, backport)

      get commits_details_topic_path(topic)

      expect(response.body.scan("Shared change").size).to eq(1)
    end

    it "applies an LLM verdict on a backport member to its group" do
      canonical = create(:commit, sha: "aaa1", subject: "Shared change", branches: [ "master" ], committed_at: 2.days.ago)
      backport = create(:commit, sha: "bbb2", subject: "Shared change", branches: [ "REL_18_STABLE" ],
                                 cherry_picked_from_sha: "aaa1", committed_at: 1.day.ago)
      link_topic(topic, canonical)
      link_topic(topic, backport)
      run = create(:patchset_run, topic: topic)
      create(:commit_verdict, patchset_run: run, commit: backport, verdict: "as_is", confidence: 0.92)

      get commits_details_topic_path(topic)

      blocks = Nokogiri::HTML(response.body).css("details.commit-llm")
      expect(blocks.size).to eq(1)
      expect(blocks.first.at_css(".commit-llm-verdict").text).to eq("landed as posted")
      expect(blocks.first.at_css(".commit-llm-confidence").text).to eq("LLM analysis, 92% sure")
    end

    it "tags reverts strictly" do
      feature = create(:commit, sha: "1adf16b8fba45f77056d91573cd7138ed9da4ebf", subject: "Implement MERGE", committed_at: 90.days.ago)
      revert = create(:commit, subject: "Revert support for MERGE", committed_at: 10.days.ago,
                               body: "This commit reverts 1adf16b8fb.")
      loose = create(:commit, subject: "Revert \"Other\"", committed_at: 5.days.ago, body: "This reverts commit 0123456789ab.")
      [ feature, revert, loose ].each { |c| link_topic(topic, c) }

      get commits_details_topic_path(topic)

      doc = Nokogiri::HTML(response.body)
      tags = doc.css(".commit-revert-tag").map(&:text)
      expect(tags).to contain_exactly("reverts 1 commit here", "revert")
    end

    it "shows the llm share of a person's credits" do
      c1, c2 = create_list(:commit, 2)
      c1.commit_people.create!(role: "author", raw_name: "Pavel Borisov")
      c2.commit_people.create!(role: "author", raw_name: "Pavel Borisov", source: "llm", confidence: 0.8)
      [ c1, c2 ].each { |c| link_topic(topic, c) }

      get commits_details_topic_path(topic)
      expect(response.body).to include(">1 LLM<")
    end
  end

  describe "commitfest_details" do
    it "renders a card per patch with history" do
      topic = create(:topic)
      patch = create(:commitfest_patch, :with_topic, topic: topic, title: "Add SPLIT PARTITION", reviewers: "Robert Haas")
      old_cf = create(:commitfest, name: "2022-07", start_date: 4.years.ago, end_date: 4.years.ago + 1.month)
      new_cf = create(:commitfest, name: "PG19-4", start_date: 2.months.ago, end_date: 1.month.ago)
      create(:commitfest_patch_commitfest, commitfest_patch: patch, commitfest: old_cf, status: "Moved to different CF")
      create(:commitfest_patch_commitfest, commitfest_patch: patch, commitfest: new_cf, status: "Committed")

      get commitfest_details_topic_path(topic)

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("turbo-frame#topic-commitfest-modal")).to be_present
      expect(response.body).to include("Add SPLIT PARTITION").and include("Committed in PG19-4").and include("Robert Haas")
      expect(doc.css(".cf-chip").map(&:text)).to eq(%w[2022-07 PG19-4])
    end
  end

  describe "patchsets_details" do
    it "has patchset and attachment tabs" do
      topic = create(:topic)
      patch_msg = create(:message, topic: topic, is_patch_submission: true)
      create(:attachment, message: patch_msg, file_name: "v1-0001-thing.patch")

      get patchsets_details_topic_path(topic)

      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("turbo-frame#topic-patchsets-modal")).to be_present
      expect(doc.css(".modal-tab").map(&:text)).to eq([ "Patchsets · 1", "All attachments · 1" ])
      expect(response.body).to include("v1-0001-thing.patch")
      expect(doc.css(".patchset-entry").size).to eq(1)
    end
  end
end
