require "rails_helper"

RSpec.describe "Global notes", type: :request do
  let(:author) { create(:user, username: "alice") }
  let(:topic) { create(:topic, last_message_at: Time.current) }
  let!(:message) { create(:message, topic: topic) }
  let!(:review_tag) { create(:global_tag, name: "needs-review", description: "Waiting for review") }

  let!(:global_note) do
    NoteBuilder.new(author:).create!(topic:, body: "@global #needs-review")
  end
  let!(:private_note) do
    NoteBuilder.new(author:).create!(topic:, body: "secret thoughts")
  end

  describe "as a guest" do
    it "shows global notes on the topic page" do
      get topic_path(topic)
      expect(response.body).to include("#needs-review", "fa-globe")
      expect(response.body).not_to include("secret thoughts")
      expect(response.body).not_to include("Add note")
    end

    it "lists global tags in the sidebar" do
      create(:global_tag, name: "unused-tag")
      create(:global_tag, name: "gone").retire!

      get topics_path
      expect(response.body).to include("Global tags", "#needs-review (1)", "#unused-tag (0)", 'title="Waiting for review"')
      expect(response.body).not_to include("#gone")
    end

    it "lists global tags on search results" do
      get search_topics_path(q: "tag:needs-review")
      expect(response.body).to include("Global tags", topic.title)
    end

    it "shows the note count icon in the topic list" do
      get topics_path
      expect(response.body).to include('title="Notes: 1"')
    end
  end

  describe "edit controls" do
    it "shows edit to admins on global notes" do
      sign_in_as(create(:user, admin: true))
      get topic_path(topic)
      expect(response.body).to include("Update note")
    end

    it "hides edit from other users" do
      sign_in_as(create(:user, username: "bob"))
      get topic_path(topic)
      expect(response.body).not_to include("Update note")
      expect(response.body).to include("note-hint")
    end
  end

  describe "My tags sidebar" do
    it "excludes other users' global tags" do
      bob = create(:user, username: "bob")
      NoteBuilder.new(author: bob).create!(topic:, body: "#mine")
      sign_in_as(bob)

      get topics_path
      section = Nokogiri::HTML(response.body).css(".sidebar-section").find { |n| n.at_css("h3")&.text&.strip == "My tags" }
      expect(section.text).to include("#mine")
      expect(section.text).not_to include("#needs-review")
    end
  end
end
