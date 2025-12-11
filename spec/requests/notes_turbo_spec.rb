require "rails_helper"

RSpec.describe "Turbo note interactions", type: :request do
  let(:user) { create(:user, password: "password", password_confirmation: "password", username: "tester") }
  let(:alias_record) { create(:alias, :primary, user:, verified_at: Time.current) }
  let(:topic) { create(:topic, creator: alias_record) }
  let(:message) { create(:message, topic:, sender: alias_record) }

  before do
    alias_record # ensure alias exists
    post session_path, params: { email: alias_record.email, password: "password" }
    expect(response).to redirect_to(root_path)
  end

  it "renders nothing for notes on show page without notes until clicked" do
    get topic_path(topic)
    expect(response.body).to include("Add note")
    expect(response.body).not_to include("note-textarea")
  end

  it "renders the note form via turbo stream for thread notes" do
    get new_note_path(topic_id: topic.id, format: :turbo_stream)

    expect(response.media_type).to eq("text/vnd.turbo-stream.html")
    expect(response.body).to include("turbo-stream", "note-form-wrapper")
  end

  it "creates a thread note via turbo stream and renders the updated stack" do
    post notes_path, params: { note: { topic_id: topic.id, body: "Thread note body" } }, headers: { "ACCEPT" => "text/vnd.turbo-stream.html" }

    expect(response.media_type).to eq("text/vnd.turbo-stream.html")
    expect(response.body).to include("Thread note body")
  end

  it "creates a message note via turbo stream and renders the updated stack" do
    post notes_path, params: { note: { topic_id: topic.id, message_id: message.id, body: "Message note body" } }, headers: { "ACCEPT" => "text/vnd.turbo-stream.html" }

    expect(response.media_type).to eq("text/vnd.turbo-stream.html")
    expect(response.body).to include("Message note body")
  end
end
