require "rails_helper"

RSpec.describe "Notes", type: :request do
  def sign_in(email:, password: "secret")
    post session_path, params: { email: email, password: password }
    expect(response).to redirect_to(root_path)
  end

  def attach_verified_alias(user, email:, primary: true)
    al = create(:alias, user: user, email: email)
    if primary && user.person&.default_alias_id.nil?
      user.person.update!(default_alias_id: al.id)
    end
    Alias.by_email(email).update_all(verified_at: Time.current)
    al
  end

  let!(:topic) { create(:topic) }
  let!(:author) { create(:user, password: "secret", password_confirmation: "secret") }
  let!(:note) { Note.create!(topic: topic, author: author, body: "Original note") }
  let!(:other_user) { create(:user, password: "secret", password_confirmation: "secret") }

  before do
    attach_verified_alias(other_user, email: "other@example.com")
    sign_in(email: "other@example.com")
  end

  describe "PATCH /notes/:id" do
    it "prevents non-authors from updating notes" do
      patch note_path(note), params: { note: { body: "Changed note" } }

      expect(response).to redirect_to(topic_path(note.topic))
      expect(note.reload.body).to eq("Original note")
    end
  end

  describe "DELETE /notes/:id" do
    it "prevents non-authors from deleting notes" do
      delete note_path(note)

      expect(response).to redirect_to(topic_path(note.topic))
      expect(note.reload.deleted_at).to be_nil
    end
  end

  describe "admin moderation" do
    let!(:admin) { create(:user, admin: true) }
    let!(:global_note) { Note.create!(topic: topic, author: author, body: "@global", global: true) }

    before { sign_in_as(admin) }

    it "lets admins delete global notes" do
      delete note_path(global_note)
      expect(global_note.reload.deleted_at).to be_present
    end

    it "does not let admins edit private notes" do
      patch note_path(note), params: { note: { body: "Changed" } }
      expect(note.reload.body).to eq("Original note")
    end
  end
end
