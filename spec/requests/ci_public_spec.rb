# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Public CI", type: :request do
  describe "navigation" do
    it "links the CI dashboard for a signed out visitor" do
      get topics_path

      page = Nokogiri::HTML(response.body)

      expect(page.at_css(".nav-links a.nav-link[href='/ci']")).to be_present
      expect(page.at_css(".mobile-nav-menu a.nav-link[href='/ci']")).to be_present
    end
  end

  describe "topic index icon" do
    let(:repo_state) { create(:patch_ci_repo_state, master_committed_at: Time.current) }

    def topic_with_patch(**attrs)
      topic = create(:topic, last_message_at: Time.current)
      message = create(:message, topic: topic, is_patch_submission: true)
      create(:patch_branch, topic: topic, message: message,
             branch_name: "t#{topic.id}_1", base_sha: repo_state.master_sha, **attrs)
      topic
    end

    def glyphs
      Nokogiri::HTML(response.body).css(".ci-icon i").map { |i| i["class"] }
    end

    it "shows a green check for a patch that applies with passing CI" do
      repo_state
      topic_with_patch(pushed_at: 1.hour.ago, ci_status: "success",
                       base_committed_at: 1.day.ago, base_commit_height: 10)

      get topics_path

      expect(glyphs.first).to include("fa-circle-check")
    end

    it "shows the apply glyph for a patch that never applied" do
      repo_state
      topic_with_patch(status: "failed", failure_stage: "apply")

      get topics_path

      expect(glyphs.first).to include("fa-file-circle-xmark")
    end

    it "shows no CI icon on a committed thread" do
      repo_state
      topic = topic_with_patch(pushed_at: 1.hour.ago, ci_status: "success",
                               base_committed_at: 1.day.ago, base_commit_height: 10)
      create(:commit_topic, topic: topic)

      get topics_path

      expect(glyphs).to eq([])
    end

    # the turbo stream replaces the whole row, so a missing preload here drops
    # the icon on every background refresh - and does it silently, since the
    # view reaches for @ci_statuses with safe navigation
    it "keeps the icon through a row_states refresh" do
      repo_state
      topic = topic_with_patch(pushed_at: 1.hour.ago, ci_status: "success",
                               base_committed_at: 1.day.ago, base_commit_height: 10)
      sign_in_as(create(:user))

      get row_states_topics_path, params: { topic_ids: [ topic.id ] }, as: :turbo_stream

      expect(glyphs.first).to include("fa-circle-check")
    end
  end

  describe "thread sidebar" do
    let(:repo_state) { create(:patch_ci_repo_state, master_committed_at: Time.current) }

    def thread_with_run(branch_attrs = {}, run_attrs = {})
      topic = create(:topic, last_message_at: Time.current)
      message = create(:message, topic: topic, is_patch_submission: true)
      branch = create(:patch_branch, topic: topic, message: message,
                      branch_name: "t#{topic.id}_1", base_sha: repo_state.master_sha,
                      pushed_at: 1.hour.ago, base_committed_at: 1.day.ago,
                      base_commit_height: 10, **branch_attrs)
      if run_attrs.any?
        run = create(:patch_ci_run, patch_branch: branch, **run_attrs)
        branch.update_columns(latest_ci_run_id: run.id)
      end
      topic
    end

    def sidebar
      Nokogiri::HTML(response.body).at_css(".ci-thread-section").to_html
    end

    it "lists the failing tests by name" do
      repo_state
      topic = thread_with_run({ ci_status: "tests_failed" },
                              { status: "tests_failed", tests_total: 5,
                                failed_tests: %w[regress/foo isolation/bar] })

      get topic_path(topic)

      expect(sidebar).to include("regress/foo").and include("isolation/bar")
      expect(sidebar).to include("3 / 5")
    end

    it "caps the failing list and says how many were dropped" do
      repo_state
      names = (1..14).map { |n| "regress/t#{n}" }
      topic = thread_with_run({ ci_status: "tests_failed" },
                              { status: "tests_failed", tests_total: 20, failed_tests: names })

      get topic_path(topic)

      expect(sidebar).to include("regress/t10")
      expect(sidebar).not_to include("regress/t11")
      expect(sidebar).to include("+4 more")
    end

    it "renders no block on a thread with no patchset" do
      repo_state
      topic = create(:topic, last_message_at: Time.current)
      create(:message, topic: topic)

      get topic_path(topic)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("ci-thread-section")
    end

    it "renders no block on a committed thread" do
      repo_state
      topic = thread_with_run({ ci_status: "success" }, { status: "success" })
      create(:commit_topic, topic: topic)

      get topic_path(topic)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("ci-thread-section")
    end
  end

  describe "thread banner" do
    let(:repo_state) { create(:patch_ci_repo_state, master_committed_at: Time.current) }
    let(:topic) { create(:topic, last_message_at: Time.current) }

    def patchset(index, **attrs)
      message = create(:message, topic: topic, is_patch_submission: true)
      create(:patch_branch, topic: topic, message: message,
             branch_name: "t#{topic.id}_#{index}", base_sha: repo_state.master_sha,
             pushed_at: 1.hour.ago, base_committed_at: 1.day.ago,
             base_commit_height: 10, **attrs)
    end

    def banner
      Nokogiri::HTML(response.body).at_css(".ci-banner").to_html
    end

    # the beta label has to land on the feature, not on the patch being
    # discussed - hence pinning the sentence and not just the word. The scope
    # line matters too: readers assume CI means commitfest submissions only.
    it "says the feature is beta and what it covers" do
      repo_state
      patchset(1, ci_status: "success")

      get topic_path(topic)

      expect(banner).to include("Beta feature")
      expect(banner).to include("not only commitfest submissions")
      expect(banner).to include("Hackorum's own CI")
    end

    it "prints the short tag and both example lines" do
      repo_state
      row = patchset(1, ci_status: "success")
      run = create(:patch_ci_run, patch_branch: row, status: "success",
                   image_ref: "ghcr.io/hackorum-dev/postgres:t#{topic.id}",
                   completed_at: Time.current)
      row.update_columns(latest_ci_run_id: run.id)

      get topic_path(topic)

      expect(banner).to include("docker run --rm -p 5432:5432 ghcr.io/hackorum-dev/postgres:t#{topic.id}")
      expect(banner).to include("psql -h localhost -U postgres")
    end

    it "names the patchset the image came from" do
      repo_state
      row = patchset(1, ci_status: "success")
      run = create(:patch_ci_run, patch_branch: row, status: "success",
                   image_ref: "ghcr.io/hackorum-dev/postgres:t#{topic.id}",
                   completed_at: Time.current)
      row.update_columns(latest_ci_run_id: run.id)

      get topic_path(topic)

      expect(banner).to include("patchset v1")
      expect(banner).not_to include("ci-banner-warning")
    end

    # the tag is per topic and every run overwrites it, so this is not a rare
    # case - a reader who pulls it would otherwise test the wrong patch
    it "warns when an older patchset owns the tag" do
      repo_state
      old = patchset(1, ci_status: "success")
      fresh = patchset(2, ci_status: "queued")
      old.update!(superseded_by: fresh)
      create(:patch_ci_run, patch_branch: old, status: "success",
             image_ref: "ghcr.io/hackorum-dev/postgres:t#{topic.id}",
             completed_at: Time.current)

      get topic_path(topic)

      expect(banner).to include("ci-banner-warning")
      expect(banner).to include("patchset v1")
      expect(banner).to include("patchset v2")
    end

    it "drops the docker section when nothing built an image" do
      repo_state
      patchset(1, ci_status: "build_failed")

      get topic_path(topic)

      expect(banner).to include("Beta feature")
      expect(banner).to include(">applies<")
      expect(banner).not_to include("docker run")
    end
  end
end
