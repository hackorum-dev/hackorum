require "rails_helper"

RSpec.describe Classify::BotNote do
  before { Classify::Setup.call! }

  let(:topic) { create(:topic) }
  let(:bot_note) { described_class.new(topic) }

  it "creates and updates one tag-only global note" do
    expect(bot_note.write!(%w[feature moderate])).to eq(:created)
    expect(bot_note.write!(%w[feature moderate])).to eq(:unchanged)
    expect(bot_note.write!(%w[feature major])).to eq(:updated)
    note = Note.where(topic:).sole
    expect(note).to have_attributes(global: true, author: Classify.bot_user, body: "@global #feature #major")
    expect(note.tag_only?).to be(true)
  end

  it "stays away from a note an admin edited" do
    bot_note.write!(%w[feature minor])
    admin = create(:user, admin: true)
    NoteBuilder.new(author: admin).update!(note: bot_note.note, body: "@global #feature #moderate")
    expect(described_class.new(topic).locked?).to be(true)
    expect(described_class.new(topic).write!(%w[feature minor])).to eq(:locked)
    expect(described_class.tags_by_topic([ topic.id ])[topic.id]).to eq(%w[feature moderate])
  end

  it "never recreates a deleted note" do
    bot_note.write!(%w[bug])
    bot_note.note.update!(deleted_at: Time.current)
    expect(described_class.new(topic).write!(%w[bug])).to eq(:locked)
    expect(Note.where(topic:).count).to eq(1)
  end

  it "ignores other users' global tags" do
    user = create(:user)
    NoteBuilder.new(author: user).create!(topic:, body: "@global #major")
    bot_note.write!(%w[feature minor])
    expect(described_class.tags_by_topic([ topic.id ])).to eq(topic.id => %w[feature minor])
  end
end

RSpec.describe Classify::BotNote, ".tags_by_topic without bot" do
  it "returns no tags when the bot user does not exist" do
    expect(described_class.tags_by_topic([ create(:topic).id ])).to eq({})
  end
end
