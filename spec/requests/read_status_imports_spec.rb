require "rails_helper"
require "cgi"

RSpec.describe "Read status imports", type: :request do
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

  def upload_csv(content)
    file = Tempfile.new([ "read-status", ".csv" ])
    file.write(content)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "text/csv")
  ensure
    file.close
  end

  it "requires authentication" do
    get settings_import_path
    expect(response).to redirect_to(new_session_path)
  end

  it "imports read status and notes with warnings and skips" do
    user = create(:user, password: "secret", password_confirmation: "secret")
    attach_verified_alias(user, email: "importer@example.com")
    sign_in(email: "importer@example.com")

    message1 = create(:message)
    message2 = create(:message)

    csv = <<~CSV
      message_id,notemode,note
      #{message1.message_id},message,Imported #tag
      #{message2.message_id},message,
      <missing@example.com>,message,Missing message
    CSV

    post settings_import_path, params: { import_file: upload_csv(csv) }

    note = Note.active.find_by(author: user, message_id: message1.id)
    expect(note).to be_present
    expect(note.body).to start_with("!autoimport")
    expect(note.note_tags.pluck(:tag)).to include("tag")

    expect(Note.active.find_by(author: user, message_id: message2.id)).to be_nil

    expect(MessageReadRange.covering?(user: user, topic: message1.topic, message_id: message1.id)).to be(true)
    expect(MessageReadRange.covering?(user: user, topic: message2.topic, message_id: message2.id)).to be(true)
    expect(ThreadAwareness.covering?(user: user, topic: message1.topic, message_id: message1.id)).to be(true)
    expect(ThreadAwareness.covering?(user: user, topic: message2.topic, message_id: message2.id)).to be(true)

    expect(response.body).to include("New notes: 1")
    expect(response.body).to include("Replaced notes: 0")
    expect(response.body).to include("Message IDs marked as read: 2")
    expect(response.body).to include("Skipped message IDs: 1")
    escaped_message_id = CGI.escapeHTML(message2.message_id)
    expect(response.body).to include("Message #{escaped_message_id}: note text missing; skipped note import.")
    expect(response.body).to include(CGI.escapeHTML("<missing@example.com>"))
  end

  it "replaces existing imported notes" do
    user = create(:user, password: "secret", password_confirmation: "secret")
    attach_verified_alias(user, email: "replacer@example.com")
    sign_in(email: "replacer@example.com")

    message = create(:message)
    Note.create!(topic: message.topic, message: message, author: user, body: "!autoimport old text")

    csv = <<~CSV
      #{message.message_id},message,New text
    CSV

    post settings_import_path, params: { import_file: upload_csv(csv) }

    note = Note.active.find_by(author: user, message_id: message.id)
    expect(note.body).to eq("!autoimport New text")
    expect(response.body).to include("New notes: 0")
    expect(response.body).to include("Replaced notes: 1")
  end

  it "imports topic-level notes for a message's topic" do
    user = create(:user, password: "secret", password_confirmation: "secret")
    attach_verified_alias(user, email: "topic-importer@example.com")
    sign_in(email: "topic-importer@example.com")

    message = create(:message)

    csv = <<~CSV
      #{message.message_id},topic,Thread note #tag
    CSV

    post settings_import_path, params: { import_file: upload_csv(csv) }

    note = Note.active.find_by(author: user, topic_id: message.topic_id, message_id: nil)
    expect(note).to be_present
    expect(note.body).to eq("!autoimport Thread note #tag")
    expect(note.note_tags.pluck(:tag)).to include("tag")
  end
end
