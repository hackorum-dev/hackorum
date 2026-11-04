require "rails_helper"

RSpec.describe "Topic sidebar", type: :request do
  def sidebar
    Nokogiri::HTML(response.body).at_css(".topic-sidebar")
  end

  def link_topic(topic, commit)
    create(:commit_topic, commit: commit, topic: topic)
    topic.update_columns(commit_count: topic.commit_topics.count)
  end

  it "summarises commits with latest, first and a strict revert chip" do
    topic = create(:topic, :with_messages)
    first = create(:commit, sha: "1adf16b8fba45f77056d91573cd7138ed9da4ebf", subject: "Implement SPLIT PARTITION",
                            committer_name: "Alexander Korotkov", committed_at: Time.zone.parse("2024-04-06"))
    revert = create(:commit, subject: "Revert support for SPLIT", committer_name: "Alexander Korotkov",
                             committed_at: Time.zone.parse("2024-08-24"), body: "This commit reverts 1adf16b8fb.")
    latest = create(:commit, subject: "doc: clarify MERGE PARTITIONS", committer_name: "Alexander Korotkov",
                             committed_at: Time.zone.parse("2026-06-30"))
    [ first, revert, latest ].each { |c| link_topic(topic, c) }

    get topic_path(topic)

    text = sidebar.text
    expect(text).to include("Committed by Alexander Korotkov")
    expect(text).to include("Latest").and include("doc: clarify MERGE PARTITIONS")
    expect(text).to include("First").and include("Implement SPLIT PARTITION")
    expect(text).to include("1 revert commit, Aug 2024")
    expect(text).not_to include("re-land")
    expect(sidebar.at_css("dialog turbo-frame#topic-commits-modal")).to be_present
    expect(response.body).not_to include("commit-credit-row")
  end

  it "shows open commitfest status and who is on it" do
    topic = create(:topic, :with_messages)
    patch = create(:commitfest_patch, :with_topic, topic: topic, reviewers: "Robert Haas", committer: "")
    create(:commitfest_patch_commitfest, commitfest_patch: patch, status: "Needs review", ci_status: "needs_rebase")

    get topic_path(topic)

    text = sidebar.text
    expect(text).to include("Needs review")
    expect(text).to include("Reviewers: Robert Haas")
    expect(text).to include("CF bot: needs rebase")
  end

  it "says all entries closed when nothing is open" do
    topic = create(:topic, :with_messages)
    patch = create(:commitfest_patch, :with_topic, topic: topic)
    create(:commitfest_patch_commitfest, commitfest_patch: patch, status: "Committed")

    get topic_path(topic)

    expect(sidebar.text).to include("Committed").and include("All entries closed")
  end

  it "shows the role strip and pins the signed-in poster" do
    topic = create(:topic)
    committer_alias = create(:alias, name: "Core Committer")
    ContributorMembership.create!(person: committer_alias.person, contributor_type: "committer")
    6.times { |i| create(:message, topic: topic, sender: committer_alias, created_at: (20 - i).hours.ago) }
    5.times do
      other = create(:alias)
      2.times { create(:message, topic: topic, sender: other, created_at: 10.hours.ago) }
    end
    my_alias = create(:alias, name: "Me Myself")
    user = create(:user)
    user.update!(person: my_alias.person)
    create(:message, topic: topic, sender: my_alias, created_at: 1.hour.ago)

    sign_in_as(user)
    get topic_path(topic)

    expect(sidebar.at_css(".role-strip")).to be_present
    expect(sidebar.css(".role-cell").map(&:text).join(" ")).to include("Committers1 · 6 msg")
    expect(sidebar.at_css(".sidebar-participant-you")).to be_present
    expect(sidebar.text).to include("Last committer message")
  end

  describe "with a CI run" do
    let(:repo_state) { create(:patch_ci_repo_state, master_committed_at: Time.current) }
    let(:topic) { create(:topic, last_message_at: Time.current) }
    let(:image_ref) { "ghcr.io/hackorum-dev/postgres:t#{topic.id}" }

    before do
      message = create(:message, topic: topic, is_patch_submission: true)
      branch = create(:patch_branch, topic: topic, message: message,
                      branch_name: "t#{topic.id}_1", base_sha: repo_state.master_sha,
                      pushed_at: 1.hour.ago, base_committed_at: 1.day.ago,
                      base_commit_height: 10, ci_status: "success")
      run = create(:patch_ci_run, patch_branch: branch, status: "success",
                                  image_ref: image_ref, completed_at: Time.current)
      branch.update_columns(latest_ci_run_id: run.id)
    end

    it "drops the CI banner from the thread" do
      get topic_path(topic)

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("ci-banner-lead")
      expect(response.body).not_to include("Beta feature")
    end

    it "shows the beta tag and the docker run button on the patch card" do
      get topic_path(topic)

      card = sidebar.at_css(".sidebar-patch-card")
      expect(card.at_css(".sidebar-beta-tag")).to be_present
      expect(card.css("button").map(&:text).join).to include("docker run")
      expect(card.at_css("button[data-controller=clipboard]")["title"]).to include(image_ref)
    end
  end

  it "omits the beta tag and docker button without a CI row" do
    topic = create(:topic)
    create(:message, topic: topic, is_patch_submission: true)

    get topic_path(topic)

    card = sidebar.at_css(".sidebar-patch-card")
    expect(card.at_css(".sidebar-beta-tag")).to be_nil
    expect(card.text).not_to include("docker run")
  end

  describe "thread block" do
    it "links the latest patch, lists the last four of a short thread, and opens the timeline" do
      topic = create(:topic)
      6.times { |i| create(:message, topic: topic, is_patch_submission: i == 1, created_at: (10 - i).hours.ago) }

      get topic_path(topic)

      expect(sidebar.css(".sidebar-jump").map(&:text)).to include("Latest patch #2")
      expect(sidebar.css(".sidebar-recent li").size).to eq(4)
      expect(sidebar.css(".sidebar-recent li a").first.text).to start_with("#3 ")
      expect(response.body).not_to include("thread-outline")
      expect(sidebar.at_css("details.sidebar-outline")).to be_nil
      trigger = sidebar.at_css("a.sidebar-block-more[href='#{timeline_topic_path(topic)}']")
      expect(trigger.text).to eq("Timeline \u203a")
      anchor = trigger.ancestors(".modal-anchor").first
      expect(anchor["data-action"]).to eq("timeline-modal:open@window->modal#openSrc")
      expect(anchor.at_css("dialog.modal-xl .modal-subtitle").text).to start_with("6 messages")
      chart = sidebar.at_css("button.activity-chart-button")
      expect(chart["data-dispatch-event-value"]).to eq("timeline-modal:open")
      expect(JSON.parse(chart["data-dispatch-detail-value"])).to eq("src" => timeline_topic_path(topic))
    end

    it "shows the unread count to a signed-in reader and not to a guest" do
      topic = create(:topic)
      messages = 3.times.map { |i| create(:message, topic: topic, created_at: (5 - i).hours.ago) }
      user = create(:user)
      MessageReadRange.add_range(user: user, topic: topic, start_id: messages.first.id, end_id: messages.first.id)

      get topic_path(topic)
      expect(sidebar.text).not_to include("Unread")

      sign_in_as(user)
      get topic_path(topic)
      expect(sidebar.css(".sidebar-jump").map(&:text)).to include("Unread (2)")
    end
  end

  it "shows the short link row at the top" do
    topic = create(:topic, :with_messages)
    topic.update!(slug: "split-merge")

    get topic_path(topic)

    row = sidebar.at_css(".sidebar-short-link")
    expect(row.text).to include("/t/split-merge")
    expect(sidebar.children.select(&:element?).first["class"]).to include("sidebar-short-link")
  end

  it "does not claim all closed while a patch was only moved" do
    topic = create(:topic, :with_messages)
    patch = create(:commitfest_patch, :with_topic, topic: topic)
    create(:commitfest_patch_commitfest, commitfest_patch: patch, status: "Moved to different CF")

    get topic_path(topic)

    expect(sidebar.text).to include("Moved to different CF")
    expect(sidebar.text).not_to include("All entries closed")
  end

  it "renders the step-through bar data" do
    topic = create(:topic)
    a = create(:alias)
    m1 = create(:message, topic: topic, sender: a, created_at: 2.hours.ago)
    m2 = create(:message, topic: topic, sender: a, created_at: 1.hour.ago)

    get topic_path(topic)

    doc = Nokogiri::HTML(response.body)
    bar = doc.at_css(".person-nav-bar")
    expect(bar["hidden"]).not_to be_nil
    expect(JSON.parse(bar["data-person-nav-messages-value"])).to eq(a.person_id.to_s => [ [ m1.id, 1 ], [ m2.id, 2 ] ])
    expect(doc.at_css("#message-#{m1.id}")["data-person-id"]).to eq(a.person_id.to_s)
  end
end
