require "rails_helper"

RSpec.describe "Bot notes in topic list counts", type: :request do
  let(:author) { create(:user, username: "alice") }
  let!(:tag) { create(:global_tag, name: "needs-review") }
  let!(:bot_only) { listed_topic }
  let!(:both) { listed_topic }

  def listed_topic
    create(:topic, last_message_at: Time.current).tap { |t| create(:message, topic: t) }
  end

  before do
    Classify::Setup.call!
    Classify::BotNote.new(bot_only).write!(%w[bug])
    Classify::BotNote.new(both).write!(%w[feature minor])
    NoteBuilder.new(author:).create!(topic: both, body: "@global #needs-review")
  end

  def note_badges
    doc = Nokogiri::HTML(response.body)
    expect(doc.at_css("tr#topic_#{bot_only.id}")).to be_present
    [ bot_only, both ].map { |t| doc.at_css("#notes_topic_#{t.id} .topic-icon-badge")&.text }
  end

  it "leaves bot notes out for guests" do
    get topics_path
    expect(note_badges).to eq([ nil, "1" ])
  end

  it "leaves bot notes out for signed-in users" do
    sign_in_as(create(:user))
    get topics_path
    expect(note_badges).to eq([ nil, "1" ])
  end

  it "still shows the bot note on the topic page" do
    get topic_path(bot_only)
    expect(response.body).to include("#bug")
  end
end
