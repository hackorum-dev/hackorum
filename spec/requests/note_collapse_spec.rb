require "rails_helper"

RSpec.describe "Collapsed tag-only notes", type: :request do
  let(:author) { create(:user, username: "alice") }
  let(:topic) { create(:topic, last_message_at: Time.current) }
  let!(:message) { create(:message, topic: topic) }

  before { sign_in_as(author) }

  def thread_block(html)
    Nokogiri::HTML(html).at_css("#thread-notes")
  end

  it "collapses a block of only tag-only notes and lists its tags" do
    builder = NoteBuilder.new(author:)
    builder.create!(topic:, body: "#needs-review")
    builder.create!(topic:, body: "#needs-review #bugfix")

    get topic_path(topic)
    block = thread_block(response.body)

    expect(block.name).to eq("details")
    expect(block["class"]).to include("notes-collapsed")
    expect(block["open"]).to be_nil
    summary = block.at_css("> summary")
    expect(summary.text).to include("Thread notes", "2 notes")
    expect(summary.css(".note-tag").map(&:text)).to eq([ "#needs-review", "#bugfix" ])
    expect(block.css("details.note-compact").size).to eq(2)
  end

  it "collapses only tag-only notes in a mixed block" do
    builder = NoteBuilder.new(author:)
    builder.create!(topic:, body: "#needs-review")
    builder.create!(topic:, body: "Real text here")

    get topic_path(topic)
    block = thread_block(response.body)

    expect(block.name).to eq("div")
    expect(block.css("details.note-compact").size).to eq(1)
    expect(block.css(".notes-list > .note-card").size).to eq(1)
    expect(block.at_css("details.note-compact > summary").text).to include("#needs-review")
  end

  it "opens the block when the form has an error" do
    NoteBuilder.new(author:).create!(topic:, body: "#needs-review")

    post notes_path, params: { note: { topic_id: topic.id, body: "@nobody-here" } }
    get topic_path(topic)
    block = thread_block(response.body)

    expect(block.name).to eq("div")
    expect(block.at_css("details.note-form-toggle")["open"]).not_to be_nil
    expect(block.text).to include("Unknown mention: @nobody-here")
  end

  it "opens a tag-only note and its edit form after a failed edit" do
    note = NoteBuilder.new(author:).create!(topic:, body: "#foo")

    patch note_path(note), params: { note: { body: "@nobody-here", topic_id: topic.id } }
    get topic_path(topic)

    compact = Nokogiri::HTML(response.body).at_css("details.note-compact")
    expect(compact["open"]).not_to be_nil
    expect(compact.at_css("details.note-edit-toggle")["open"]).not_to be_nil
    expect(compact.text).to include("Unknown mention: @nobody-here")
  end
end
