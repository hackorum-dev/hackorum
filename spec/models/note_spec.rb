require "rails_helper"

RSpec.describe Note, type: :model do
  let(:topic) { create(:topic) }
  let(:message) { create(:message, topic: topic) }
  let(:author) { create(:user, username: "author") }

  it "is invalid when message belongs to a different topic" do
    other_topic = create(:topic)
    note = described_class.new(topic: topic, message: create(:message, topic: other_topic), author: author, body: "oops")

    expect(note).not_to be_valid
    expect(note.errors[:message]).to include("must belong to the same topic")
  end

  it "is visible to author, mentioned users, and team members" do
    mentioned_user = create(:user, username: "bob")
    team = create(:team, name: "team-one")
    team_member = create(:user, username: "carol")
    create(:team_member, team:, user: team_member)
    outsider = create(:user, username: "outsider")

    note = described_class.create!(topic:, message:, author:, body: "hello world")
    note.note_mentions.create!(mentionable: mentioned_user)
    note.note_mentions.create!(mentionable: team)

    expect(described_class.visible_to(author)).to include(note)
    expect(described_class.visible_to(mentioned_user)).to include(note)
    expect(described_class.visible_to(team_member)).to include(note)
    expect(described_class.visible_to(outsider)).to be_empty
  end

  describe "global visibility" do
    let(:outsider) { create(:user, username: "outsider") }
    let!(:global_note) { described_class.create!(topic:, author:, body: "@global #x", global: true) }
    let!(:private_note) { described_class.create!(topic:, author:, body: "private") }

    it "shows only global notes to guests" do
      expect(described_class.visible_to(nil)).to contain_exactly(global_note)
    end

    it "shows global notes to any user" do
      expect(described_class.visible_to(outsider)).to contain_exactly(global_note)
    end

    it "hides deleted global notes" do
      global_note.update!(deleted_at: Time.current)
      expect(described_class.visible_to(nil)).to be_empty
    end
  end

  describe "#tag_only?" do
    def note_with(body) = described_class.new(body:)

    it "is true for tags, mentions and whitespace" do
      expect(note_with("#a @b\n  #c")).to be_tag_only
      expect(note_with("#a.")).not_to be_tag_only
    end

    it "is false with other text" do
      expect(note_with("#a fix this")).not_to be_tag_only
      expect(note_with("mail a@b.com")).not_to be_tag_only
      expect(note_with("#a, #b")).not_to be_tag_only
    end
  end

  describe "#editable_by?" do
    let(:admin) { create(:user, username: "boss", admin: true) }
    let(:other) { create(:user, username: "other") }

    it "allows the author" do
      note = described_class.new(author:, body: "x")
      expect(note.editable_by?(author)).to be(true)
    end

    it "allows admins only on global notes" do
      expect(described_class.new(author:, body: "x", global: true).editable_by?(admin)).to be(true)
      expect(described_class.new(author:, body: "x").editable_by?(admin)).to be(false)
    end

    it "rejects others and guests" do
      note = described_class.new(author:, body: "x", global: true)
      expect(note.editable_by?(other)).to be(false)
      expect(note.editable_by?(nil)).to be(false)
    end
  end
end
