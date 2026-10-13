require "rails_helper"

RSpec.describe NoteBuilder do
  let(:topic) { create(:topic) }
  let(:message) { create(:message, topic: topic) }
  let(:author) { create(:user, username: "alice") }

  it "creates notes with mentions, tags, and activities" do
    mentioned_user = create(:user, username: "bob")
    team = create(:team, name: "team-two")
    team_member = create(:user, username: "carl")
    create(:team_member, team:, user: team_member)
    create(:team_member, team:, user: author) # author must be member to mention private team

    note = described_class.new(author: author).create!(topic:, message:, body: "Ping @bob and @team-two #Foo #bar")

    expect(note.note_tags.pluck(:tag)).to match_array(%w[foo bar])
    expect(note.note_mentions.map(&:mentionable)).to match_array([ mentioned_user, team ])

    activity_users = Activity.where(subject: note).pluck(:user_id)
    expect(activity_users).to include(author.id, mentioned_user.id, team_member.id)
    expect(Activity.find_by(user: author, subject: note).activity_type).to eq("note_created")
    expect(Activity.find_by(user: mentioned_user, subject: note).activity_type).to eq("note_mentioned")
  end

  it "updates mentions and hides removed recipients" do
    bob = create(:user, username: "bob")
    devs = create(:team, name: "devs")
    dev_member = create(:user, username: "dave")
    create(:team_member, team: devs, user: dev_member)
    create(:team_member, team: devs, user: author) # author must be member to mention private team
    carol = create(:user, username: "carol")

    builder = described_class.new(author: author)
    note = builder.create!(topic:, message:, body: "Hi @bob and @devs")
    builder.update!(note:, body: "Hi @bob and @carol")

    old_activity = Activity.find_by(user: dev_member, subject: note)
    new_activity = Activity.find_by(user: carol, subject: note)

    expect(old_activity.hidden).to eq(true)
    expect(new_activity).to be_present
  end

  describe "mention restrictions" do
    describe "team visibility" do
      it "allows mentioning private teams when author is a member" do
        private_team = create(:team, name: "private-team", visibility: :private)
        create(:team_member, team: private_team, user: author)

        expect {
          described_class.new(author: author).create!(topic:, body: "Hi @private-team")
        }.not_to raise_error
      end

      it "blocks mentioning private teams when author is not a member" do
        private_team = create(:team, name: "private-team", visibility: :private)

        expect {
          described_class.new(author: author).create!(topic:, body: "Hi @private-team")
        }.to raise_error(NoteBuilder::Error, /only team members can mention this team/)
      end

      it "blocks mentioning visible teams when author is not a member" do
        visible_team = create(:team, name: "visible-team", visibility: :visible)

        expect {
          described_class.new(author: author).create!(topic:, body: "Hi @visible-team")
        }.to raise_error(NoteBuilder::Error, /only team members can mention this team/)
      end

      it "allows mentioning open teams by anyone" do
        open_team = create(:team, name: "open-team", visibility: :open)

        expect {
          described_class.new(author: author).create!(topic:, body: "Hi @open-team")
        }.not_to raise_error
      end
    end

    describe "user mention_restriction" do
      it "allows mentioning users with anyone setting" do
        bob = create(:user, username: "bob", mention_restriction: :anyone)

        expect {
          described_class.new(author: author).create!(topic:, body: "Hi @bob")
        }.not_to raise_error
      end

      it "allows teammates to mention users with teammates_only setting" do
        bob = create(:user, username: "bob", mention_restriction: :teammates_only)
        team = create(:team, name: "shared-team")
        create(:team_member, team: team, user: author)
        create(:team_member, team: team, user: bob)

        expect {
          described_class.new(author: author).create!(topic:, body: "Hi @bob")
        }.not_to raise_error
      end

      it "blocks non-teammates from mentioning users with teammates_only setting" do
        bob = create(:user, username: "bob", mention_restriction: :teammates_only)

        expect {
          described_class.new(author: author).create!(topic:, body: "Hi @bob")
        }.to raise_error(NoteBuilder::Error, /only their teammates can mention them/)
      end
    end
  end

  it "does not include a trailing dot in tags or mentions" do
    create(:user, username: "bob")
    note = described_class.new(author:).create!(topic:, body: "Ask @bob. See #foo.bar.")

    expect(note.note_tags.pluck(:tag)).to eq([ "foo.bar" ])
    expect(note.note_mentions.map(&:mentionable).map(&:username)).to eq([ "bob" ])
  end

  describe "@global" do
    let!(:review_tag) { create(:global_tag, name: "needs-review") }
    let(:admin) { create(:user, username: "boss", admin: true) }
    let(:other) { create(:user, username: "other") }

    it "marks the note global without a mention row or extra activities" do
      note = described_class.new(author:).create!(topic:, body: "@global #needs-review")

      expect(note.global).to be(true)
      expect(note.note_tags.pluck(:tag)).to eq(%w[needs-review])
      expect(note.note_mentions).to be_empty
      expect(Activity.where(subject: note).pluck(:user_id)).to eq([ author.id ])
    end

    it "rejects unknown and retired tags" do
      create(:global_tag, name: "old").retire!

      expect {
        described_class.new(author:).create!(topic:, body: "@global #nope")
      }.to raise_error(NoteBuilder::Error, "Unknown global tag #nope")
      expect {
        described_class.new(author:).create!(topic:, body: "@global #old")
      }.to raise_error(NoteBuilder::Error, "Unknown global tag #old")
    end

    it "keeps a retired tag already on the note" do
      old = create(:global_tag, name: "old")
      note = described_class.new(author:).create!(topic:, body: "@global #old")
      old.retire!

      described_class.new(author:).update!(note:, body: "@global #old #needs-review")
      expect(note.reload.note_tags.pluck(:tag)).to match_array(%w[old needs-review])
    end

    it "does not carry private tags into a global note" do
      note = described_class.new(author:).create!(topic:, body: "#mine")

      expect {
        described_class.new(author:).update!(note:, body: "@global #mine")
      }.to raise_error(NoteBuilder::Error, "Unknown global tag #mine")
    end

    it "clears the flag when @global is removed" do
      note = described_class.new(author:).create!(topic:, body: "@global #needs-review")
      described_class.new(author:).update!(note:, body: "#needs-review")

      expect(note.reload.global).to be(false)
    end

    it "rejects a global note without tags" do
      expect {
        described_class.new(author:).create!(topic:, body: "@global hello")
      }.to raise_error(NoteBuilder::Error, "Global notes need at least one global tag")
    end

    it "checks mentions as the note owner on admin edits" do
      team = create(:team, name: "core")
      create(:team_member, team:, user: author)
      bob = create(:user, username: "bob", mention_restriction: :teammates_only)
      create(:team_member, team:, user: bob)
      note = described_class.new(author:).create!(topic:, body: "@global #needs-review")

      described_class.new(author: admin).update!(note:, body: "@global #needs-review @bob")

      expect(note.reload.note_mentions.map(&:mentionable)).to eq([ bob ])
    end

    it "lets admins edit global notes only" do
      global_note = described_class.new(author:).create!(topic:, body: "@global #needs-review")
      private_note = described_class.new(author:).create!(topic:, body: "mine")

      described_class.new(author: admin).update!(note: global_note, body: "@global #needs-review ok")
      expect(global_note.reload.last_editor).to eq(admin)

      expect {
        described_class.new(author: admin).update!(note: private_note, body: "x")
      }.to raise_error(NoteBuilder::Error)
      expect {
        described_class.new(author: other).update!(note: global_note, body: "x")
      }.to raise_error(NoteBuilder::Error)
    end
  end
end
