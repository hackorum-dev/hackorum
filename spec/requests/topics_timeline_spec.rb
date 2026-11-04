require "rails_helper"

RSpec.describe "Topic timeline", type: :request do
  def frame = Nokogiri::HTML(response.body).at_css("turbo-frame#topic-timeline-modal")

  it "lists a short thread without chapters, grouped by week" do
    topic = create(:topic)
    a = create(:alias, name: "Author One")
    first = create(:message, topic: topic, sender: a, created_at: Time.zone.parse("2026-10-03 10:00"))
    create(:message, topic: topic, sender: a, reply_to: first, created_at: Time.zone.parse("2026-10-04 10:00"), is_patch_submission: true)

    get timeline_topic_path(topic)

    expect(response).to have_http_status(:ok)
    expect(frame.css(".timeline-chapter-button")).to be_empty
    expect(frame.css(".timeline-row").size).to eq(2)
    expect(frame.text).to include("Week of")
    expect(frame.css(".timeline-row .timeline-tag-patch").size).to eq(1)
    expect(frame.css(".timeline-tag-reply")).to be_empty
  end

  it "splits a long thread into dated chapters and preselects the last" do
    topic = create(:topic)
    a = create(:alias)
    40.times { |i| create(:message, topic: topic, sender: a, created_at: Time.zone.parse("2022-05-01") + i.days) }
    30.times { |i| create(:message, topic: topic, sender: a, created_at: Time.zone.parse("2024-04-01") + i.hours) }

    get timeline_topic_path(topic)

    buttons = frame.css("[data-timeline-target=chapterButton]")
    expect(buttons.map { |b| b.at_css(".timeline-chapter-label").text }).to eq([ "May - Jun 2022", "Apr 2024" ])
    expect(frame.at_css("[data-controller=timeline]")["data-timeline-chapter-value"]).to eq("1")
    whole = frame.css(".timeline-chapter-whole")
    expect(whole.size).to eq(1)
    expect(whole.first.text).to include("Whole thread", "70 msgs")
    expect(frame.css(".timeline-chapters button").first["class"]).to include("timeline-chapter-whole")
  end

  it "renders people controls: All, None and per-person only buttons" do
    topic = create(:topic)
    a = create(:alias, name: "Ann Author")
    b = create(:alias, name: "Bob Builder")
    create(:message, topic: topic, sender: a)
    create(:message, topic: topic, sender: b)

    get timeline_topic_path(topic)

    expect(frame.css(".timeline-filter-head .timeline-link").map { |l| l.text.strip }).to eq(%w[All None])
    expect(frame.css(".timeline-person-only").size).to eq(2)
    expect(frame.css(".timeline-person-name").map(&:text)).to contain_exactly("Ann Author", "Bob Builder")
    expect(frame.at_css("[data-timeline-target=noPeople]").text).to include("Pick at least one person")
    expect(frame.css(".timeline-chapter-whole")).to be_empty
  end

  it "preselects one person" do
    topic = create(:topic)
    a = create(:alias)
    b = create(:alias)
    create(:message, topic: topic, sender: a)
    create(:message, topic: topic, sender: b)

    get timeline_topic_path(topic, person: b.person_id)

    checked = frame.css("input[data-timeline-target=person][checked]").map { |c| c["value"] }
    expect(checked).to eq([ b.person_id.to_s ])
  end

  it "inserts commits and folds busy days of a long thread" do
    topic = create(:topic)
    a = create(:alias)
    day = Time.zone.parse("2026-06-16 08:00")
    55.times { |i| create(:message, topic: topic, sender: a, created_at: day - (i + 1).days) }
    9.times { |i| create(:message, topic: topic, sender: a, created_at: day + i.minutes) }
    commit = create(:commit, subject: "Revert the thing", committed_at: day + 1.hour)
    create(:commit_topic, topic: topic, commit: commit)

    get timeline_topic_path(topic)

    expect(frame.css("details.timeline-day").size).to eq(1)
    expect(frame.at_css("details.timeline-day summary").text).to include("Tue 16 Jun 2026", "9 messages")
    expect(frame.at_css(".timeline-commit.is-revert").text).to include("Revert the thing")
  end

  it "does not fold a short thread" do
    topic = create(:topic)
    a = create(:alias)
    9.times { |i| create(:message, topic: topic, sender: a, created_at: Time.zone.parse("2026-06-16 08:00") + i.minutes) }

    get timeline_topic_path(topic)

    expect(frame.css("details.timeline-day")).to be_empty
    expect(frame.css(".timeline-row").size).to eq(9)
  end

  it "marks far replies only" do
    topic = create(:topic)
    a = create(:alias)
    root = create(:message, topic: topic, sender: a, created_at: 3.days.ago)
    create(:message, topic: topic, sender: a, reply_to: root, created_at: 2.days.ago)
    create(:message, topic: topic, sender: a, reply_to: root, created_at: 1.day.ago)

    get timeline_topic_path(topic)

    expect(frame.css(".timeline-tag-reply").map(&:text)).to eq([ "↳ #1" ])
  end

  it "flags only my own notes for the My notes filter" do
    topic = create(:topic)
    me = create(:user)
    mine = create(:message, topic: topic, created_at: 2.days.ago)
    theirs = create(:message, topic: topic, created_at: 1.day.ago)
    create(:note, topic: topic, message: mine, author: me)
    create(:note, topic: topic, message: theirs, global: true)
    sign_in_as(me)

    get timeline_topic_path(topic)

    rows = frame.css(".timeline-row").index_by { |r| r["href"] }
    expect(rows["#message-#{mine.id}"]["data-noted"]).to eq("1")
    expect(rows["#message-#{theirs.id}"]["data-noted"]).to be_nil
    expect(rows["#message-#{theirs.id}"].at_css(".timeline-tag-note")).to be_present
  end

  it "shows commits before the first message of a short thread, reverts as commits" do
    topic = create(:topic)
    create(:message, topic: topic, created_at: Time.zone.parse("2026-10-03 10:00"))
    commit = create(:commit, subject: "Revert early thing", committed_at: Time.zone.parse("2026-09-01 10:00"))
    create(:commit_topic, topic: topic, commit: commit)

    get timeline_topic_path(topic)

    row = frame.at_css(".timeline-commit.is-revert")
    expect(row.text).to include("Committed").and include("Revert early thing")
    expect(row.text).not_to include("Reverted")
  end

  it "redirects a merged topic to the target timeline" do
    target = create(:topic)
    merged = create(:topic)
    merged.update!(merged_into_topic: target)

    get timeline_topic_path(merged, person: 5)

    expect(response).to redirect_to(timeline_topic_path(target, person: 5))
  end
end
