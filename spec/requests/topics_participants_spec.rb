require "rails_helper"

RSpec.describe "Topic participants", type: :request do
  let(:topic) { create(:topic) }
  let(:busy) { create(:alias, name: "Busy Person") }
  let(:quiet) { create(:alias, name: "Quiet Person") }

  before do
    ContributorMembership.create!(person: busy.person, contributor_type: "committer")
    3.times { |i| create(:message, topic: topic, sender: busy, created_at: (10 - i).days.ago) }
    create(:message, topic: topic, sender: quiet, created_at: 1.day.ago)
  end

  it "lists everyone by activity with numbers" do
    get participants_topic_path(topic)

    doc = Nokogiri::HTML(response.body)
    rows = doc.css("turbo-frame#topic-participants-modal .people-row")
    expect(rows.map { |r| r.at_css(".people-name a[data-turbo-frame]").text.strip }).to eq([ "Busy Person", "Quiet Person" ])
    expect(rows.first.text).to include("Committers").and include("#1").and include("#3")
    expect(rows.last.text).to include("#4")
  end

  it "links each name into the same frame, no nested modal" do
    get participants_topic_path(topic)

    doc = Nokogiri::HTML(response.body)
    link = doc.at_css("a[data-turbo-frame='topic-participants-modal'][href='#{participant_topic_path(topic, person_id: quiet.person_id, frame: 'topic-participants-modal')}']")
    expect(link.text.strip).to eq("Quiet Person")
    expect(doc.css("[data-modal-trigger]")).to be_empty
    expect(doc.css("turbo-frame[id$='-list']")).to be_empty
  end

  describe "participant" do
    it "shows one person's activity and actions" do
      commit = create(:commit)
      create(:commit_topic, topic: topic, commit: commit)
      commit.commit_people.create!(role: "author", raw_name: "Busy Person", person: busy.person)
      commit.commit_people.create!(role: "reviewer", raw_name: "Busy Person", person: busy.person, source: "llm", confidence: 0.9)

      get participant_topic_path(topic, person_id: busy.person_id)

      doc = Nokogiri::HTML(response.body)
      frame = doc.at_css("turbo-frame#topic-person-#{busy.person_id}")
      expect(frame.text).to include("3 messages")
      expect(frame.css(".person-strip-tick").size).to eq(3)
      expect(frame.text).to include("First · #1").and include("Latest · #3")
      expect(frame.text).to include("1 commit authored")
      expect(frame.text).not_to include("reviewed")
      expect(frame.at_css("[data-action~='person-actions#stepThrough']")).to be_present
    end

    it "uses the participants frame with a back link, and ignores other frames" do
      pid = busy.person_id
      get participant_topic_path(topic, person_id: pid, frame: "topic-participants-modal")
      doc = Nokogiri::HTML(response.body)
      frame = doc.at_css("turbo-frame#topic-participants-modal")
      back = frame.at_css("a.people-back[data-turbo-frame='topic-participants-modal']")
      expect(back.text).to include("All participants")
      expect(back["href"]).to eq(participants_topic_path(topic))
      expect(frame.at_css(".person-card")).to be_present

      get participant_topic_path(topic, person_id: pid, frame: "topic-person-#{pid}-list")
      expect(Nokogiri::HTML(response.body).at_css("turbo-frame#topic-person-#{pid}")).to be_present
      get participant_topic_path(topic, person_id: pid, frame: "evil")
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css("turbo-frame#topic-person-#{pid}")).to be_present
      expect(doc.at_css(".people-back")).to be_nil
    end

    it "falls back to the message alias without a default alias" do
      busy.person.update_columns(default_alias_id: nil)

      get participant_topic_path(topic, person_id: busy.person_id)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Busy Person")
    end

    it "404s for someone not in the thread" do
      outsider = create(:alias)
      get participant_topic_path(topic, person_id: outsider.person_id)
      expect(response).to have_http_status(:not_found)
    end
  end
end
