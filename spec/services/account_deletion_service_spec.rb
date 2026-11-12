require "rails_helper"

RSpec.describe AccountDeletionService do
  let(:user) { create(:user, username: "leaver", password: "secret", password_confirmation: "secret") }
  let(:person) { user.person }
  let(:topic) { create(:topic) }

  before { allow(Net::HTTP).to receive(:post_form).and_return(double(code: "200", body: "")) }

  def call = described_class.new(user).call

  it "keeps a tombstone without credentials or username, but keeps the reservation" do
    call
    user.reload
    expect(user.deleted_at).to be_present
    expect(user.username).to be_nil
    expect(user.password_digest).to be_nil
    expect(user.person_id).to be_nil
    expect(NameReservation.find_by(name: "leaver")).to be_present
  end

  it "deletes aliases that never appeared in the archive, and their person" do
    al = create(:alias, user: user, person: person, email: "private@example.com", verified_at: Time.current)
    call
    expect(Alias.exists?(al.id)).to be false
    expect(Person.exists?(person.id)).to be false
  end

  it "detaches archive aliases and keeps the person" do
    private_al = create(:alias, user: user, person: person, email: "private@example.com", verified_at: Time.current)
    archive_al = create(:alias, user: user, person: person, email: "hacker@example.com", verified_at: Time.current)
    create(:message, sender_alias: archive_al, topic: topic)
    call
    expect(Alias.exists?(private_al.id)).to be false
    expect(archive_al.reload).to have_attributes(user_id: nil, verified_at: nil)
    expect(person.reload.default_alias_id).to eq(archive_al.id)
  end

  it "deletes private notes and keeps global ones" do
    private_note = create(:note, author: user, topic: topic)
    global_note = create(:note, author: user, topic: topic, global: true)
    call
    expect(Note.exists?(private_note.id)).to be false
    expect(global_note.reload.author_id).to eq(user.id)
    expect(ApplicationController.helpers.display_name_for_user(global_note.author)).to eq("Deleted user")
  end

  it "deletes personal state" do
    other = create(:user)
    other_note = create(:note, author: other, topic: topic)
    NoteMention.create!(note: other_note, mentionable: user)
    TopicStar.create!(user: user, topic: topic)
    TopicIgnore.create!(user: user, topic: topic)
    UserFeature.create!(user: user, feature: "email_sending")
    search = SavedSearch.create!(name: "mine", query: "foo", scope: "user", user: user)
    create(:identity, user: user, refresh_token: "r-tok")

    call

    expect(NoteMention.where(mentionable: user)).to be_empty
    expect(TopicStar.where(user_id: user.id)).to be_empty
    expect(TopicIgnore.where(user_id: user.id)).to be_empty
    expect(UserFeature.where(user_id: user.id)).to be_empty
    expect(SavedSearch.exists?(search.id)).to be false
    expect(Identity.where(user_id: user.id)).to be_empty
    expect(Net::HTTP).to have_received(:post_form).with(URI("https://oauth2.googleapis.com/revoke"), token: "r-tok")
  end

  it "deletes drafts and their attachments" do
    draft = create(:outgoing_draft, user: user)
    create(:draft_attachment, outgoing_draft: draft)

    call

    expect(OutgoingDraft.where(user_id: user.id)).to be_empty
    expect(DraftAttachment.where(outgoing_draft_id: draft.id)).to be_empty
  end

  it "deletes drafts made and edited through tokens, and the tokens" do
    token = ApiToken.issue!(user: user, name: "laptop").first
    other = create(:outgoing_draft, created_via_token: token, last_edited_via_token: token)
    create(:outgoing_draft, user: user, created_via_token: token, last_edited_via_token: token)

    call

    expect(OutgoingDraft.where(user_id: user.id)).to be_empty
    expect(ApiToken.where(user_id: user.id)).to be_empty
    expect(other.reload).to have_attributes(created_via_token_id: nil, last_edited_via_token_id: nil)
  end
end
