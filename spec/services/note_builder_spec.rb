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
end
