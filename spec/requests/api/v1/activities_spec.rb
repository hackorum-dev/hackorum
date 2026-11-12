require "rails_helper"

RSpec.describe "API v1 activities", type: :request do
  let(:user) { create(:user, username: "alice") }
  let(:other) { create(:user, username: "bob") }
  let(:sender) { create(:alias, :with_sent_messages, name: "Tom Sender", email: "tom@example.org") }
  let(:topic) { create(:topic, creator_alias: sender, title: "Add a feature", slug: "add-feature") }
  let(:start) { Time.zone.parse("2026-03-01 10:00:00") }
  let(:entry_keys) { %w[id type created_at read_at topic message_id note_id title] }
  let(:path) { "/api/v1/me/activities" }

  def bearer(owner)
    { "Authorization" => "Bearer #{ApiToken.issue!(user: owner, name: 'laptop').last}" }
  end

  def body
    JSON.parse(response.body)
  end

  def data
    body["data"]
  end

  def ids
    data.map { |row| row["id"] }
  end

  def error_code
    body.dig("error", "code")
  end

  def message_activity(owner: user, message: create(:message, topic: topic, sender: sender), **attrs)
    create(:activity, :for_message, user: owner, subject: message, created_at: start, **attrs)
  end

  def note_activity(owner: user, type: "note_mentioned", note: nil, **attrs)
    note ||= create(:note, topic: topic, author: other, body: "secret words")
    create(:note_mention, note: note, mentionable: owner) unless note.author_id == owner.id
    create(:activity, user: owner, subject: note, activity_type: type, created_at: start,
                      payload: { topic_id: note.topic_id, message_id: note.message_id }, **attrs)
  end

  def activities_as(owner, **params)
    get path, params: params, headers: bearer(owner)
    expect(response).to have_http_status(:ok)
    ids
  end

  def topic_ref(of)
    {
      "id" => of.id, "slug" => of.slug, "title" => of.title,
      "url" => "http://www.example.com/api/v1/topics/#{of.id}", "html_url" => "http://www.example.com/topics/#{of.id}"
    }
  end

  it "needs a token" do
    get path

    expect(response).to have_http_status(:unauthorized)
    expect(error_code).to eq("token_required")
    expect(response.headers["WWW-Authenticate"]).to eq("Bearer")
  end

  it "gives the documented entries, newest first" do
    message = create(:message, topic: topic, sender: sender)
    received = message_activity(message: message, read_at: start + 1.hour)
    on_message = create(:note, topic: topic, author: other, message: message)
    mentioned = note_activity(note: on_message)
    own = note_activity(type: "note_created", note: create(:note, topic: topic, author: user))

    expect(activities_as(user)).to eq([ own.id, mentioned.id, received.id ])

    expect(body.keys).to match_array(%w[data next_cursor])
    expect(body["next_cursor"]).to be_nil
    expect(data.map(&:keys)).to all(match_array(entry_keys))
    expect(data.last).to eq(
      "id" => received.id, "type" => "topic_message_received", "created_at" => "2026-03-01T10:00:00.000Z",
      "read_at" => "2026-03-01T11:00:00.000Z", "topic" => topic_ref(topic), "message_id" => message.id,
      "note_id" => nil, "title" => "New message from Tom Sender"
    )
    expect(data[1]).to eq(
      "id" => mentioned.id, "type" => "note_mentioned", "created_at" => "2026-03-01T10:00:00.000Z",
      "read_at" => nil, "topic" => topic_ref(topic), "message_id" => message.id,
      "note_id" => on_message.id, "title" => "Note mentioned"
    )
    expect(data.first).to include("type" => "note_created", "message_id" => nil, "title" => "Note created",
                                  "note_id" => own.subject_id)
    expect(response.body).not_to include("secret words", "example.org")
  end

  it "labels the entries as the site does" do
    activities = [ message_activity, note_activity ]

    activities_as(user)

    labels = activities.reverse.map { |row| ApplicationController.helpers.activity_type_label(row.reload) }
    expect(data.map { |row| row["title"] }).to eq(labels)
  end

  it "gives only the caller's activities and never a hidden one" do
    own = message_activity
    message_activity(hidden: true)
    note_activity(hidden: true, read_at: start)
    foreign = message_activity(owner: other)
    foreign_note = note_activity(owner: other, type: "note_created", note: create(:note, topic: topic, author: other))

    expect(activities_as(user)).to eq([ own.id ])
    expect(activities_as(other)).to eq([ foreign_note.id, foreign.id ])
    expect(activities_as(create(:user))).to eq([])
  end

  it "filters on unread and rejects another value" do
    unread = message_activity
    message_activity(read_at: start)
    message_activity(hidden: true)

    expect(activities_as(user, unread: "true")).to eq([ unread.id ])
    expect(activities_as(user).size).to eq(2)

    [ "false", "1", "yes", "TRUE" ].each do |value|
      get path, params: { unread: value }, headers: bearer(user)
      expect(response).to have_http_status(:bad_request), value
      expect(error_code).to eq("invalid_parameter"), value
    end
    get "#{path}?unread[]=true", headers: bearer(user)
    expect(error_code).to eq("invalid_parameter")
    get path, params: { q: "x" }, headers: bearer(user)
    expect(error_code).to eq("invalid_parameter")
  end

  it "keeps an entry whose subject is gone, without ids" do
    gone_message = message_activity
    gone_note = note_activity
    orphan = message_activity
    kept = message_activity
    Message.where(id: gone_message.subject_id).delete_all
    NoteMention.where(note_id: gone_note.subject_id).delete_all
    Note.where(id: gone_note.subject_id).delete_all
    orphan.update_columns(payload: { topic_id: 999_999_999, message_id: 999_999_999 }, subject_id: 999_999_999)

    expect(activities_as(user)).to eq([ kept.id, orphan.id, gone_note.id, gone_message.id ])

    expect(data[3]).to include("topic" => topic_ref(topic), "message_id" => nil, "note_id" => nil,
                               "title" => "Topic message received")
    expect(data[2]).to include("topic" => topic_ref(topic), "message_id" => nil, "note_id" => nil,
                               "title" => "Note mentioned")
    expect(data[1]).to include("topic" => nil, "message_id" => nil, "note_id" => nil)
    expect(data[0]["message_id"]).to eq(kept.subject_id)
  end

  it "takes an entry without a payload" do
    with_subject = message_activity(payload: nil)
    without = message_activity(payload: nil)
    without.update_columns(subject_id: 999_999_999)

    expect(activities_as(user)).to eq([ without.id, with_subject.id ])
    expect(data.map { |row| row["topic"] }).to eq([ nil, topic_ref(topic) ])
  end

  it "does not point at a note the caller can no longer see" do
    deleted = note_activity
    deleted.subject.update_columns(deleted_at: Time.current)
    unmentioned = note_activity
    NoteMention.where(note_id: unmentioned.subject_id).delete_all
    seen = note_activity
    public_note = note_activity(note: create(:note, topic: topic, author: other, global: true))
    NoteMention.where(note_id: public_note.subject_id).delete_all

    expect(activities_as(user)).to eq([ public_note.id, seen.id, unmentioned.id, deleted.id ])

    expect(data.map { |row| row["note_id"] }).to eq([ public_note.subject_id, seen.subject_id, nil, nil ])
    expect(data.last(2)).to all(include("message_id" => nil, "title" => "Note mentioned", "topic" => topic_ref(topic)))
  end

  it "names the topic a merged thread went to" do
    target = create(:topic, creator_alias: sender, title: "The kept thread")
    received = message_activity
    noted = note_activity
    Message.where(topic_id: topic.id).update_all(topic_id: target.id)
    Note.where(topic_id: topic.id).update_all(topic_id: target.id)
    topic.update_columns(merged_into_topic_id: target.id)

    expect(activities_as(user)).to eq([ noted.id, received.id ])
    expect(data.map { |row| row["topic"] }).to all(eq(topic_ref(target)))
  end

  it "pages through the visible activities without gaps or repeats" do
    expected = Array.new(5) { |i| i.even? ? message_activity.id : note_activity.id }.reverse
    message_activity(hidden: true)
    message_activity(owner: other)
    headers = bearer(user)

    seen = []
    cursor = nil
    3.times do
      get path, params: { limit: 2, cursor: cursor }.compact, headers: headers
      expect(response).to have_http_status(:ok)
      seen.concat(ids)
      cursor = body["next_cursor"]
    end

    expect(seen).to eq(expected)
    expect(cursor).to be_nil
  end

  it "ties a cursor to its caller and its filter" do
    2.times { message_activity }
    2.times { message_activity(owner: other) }
    own = bearer(user)

    get path, params: { limit: 1 }, headers: own
    cursor = body["next_cursor"]
    expect(cursor).to be_present

    get path, params: { limit: 5, cursor: cursor }, headers: bearer(user)
    expect(response).to have_http_status(:ok)
    expect(data.size).to eq(1)

    [ [ { cursor: cursor }, bearer(other) ], [ { cursor: cursor, unread: "true" }, own ] ].each do |params, headers|
      get path, params: params, headers: headers
      expect(response).to have_http_status(:bad_request)
      expect(error_code).to eq("invalid_cursor")
    end
  end

  it "runs the same queries for one activity of each kind and for three" do
    build = lambda do
      thread = create(:topic, creator_alias: create(:alias))
      message_activity(message: create(:message, topic: thread, sender: create(:alias)))
      note_activity(note: create(:note, topic: create(:topic, creator_alias: sender), author: create(:user)))
    end
    headers = bearer(user)
    get "/api/v1/me", headers: headers
    build.call
    one = captured_queries { get path, headers: headers }
    expect(data.size).to eq(2)

    2.times { build.call }
    three = captured_queries { get path, headers: headers }

    expect(data.size).to eq(6)
    expect(data.map { |row| row["topic"]["id"] }.uniq.size).to eq(6)
    expect(data.map { |row| row["title"] }.uniq.size).to eq(4)
    expect(three.size).to eq(one.size)
  end

  it "reads no message or note text" do
    message = create(:message, topic: topic, sender: sender, body: "long message text")
    message_activity(message: message)
    note_activity(note: create(:note, topic: topic, author: other, message: message))
    note_activity(type: "note_created", note: create(:note, topic: topic, author: user))
    gone = note_activity
    NoteMention.where(note_id: gone.subject_id).delete_all
    headers = bearer(user)
    get "/api/v1/me", headers: headers

    queries = captured_queries { get path, headers: headers }

    expect(response).to have_http_status(:ok)
    expect(data.map { |row| row["title"] }).to eq([ "Note mentioned", "Note created", "Note mentioned",
                                                    "New message from Tom Sender" ])
    expect(data.map { |row| row["note_id"].nil? }).to eq([ true, false, false, true ])
    expect(queries.grep(/FROM "(messages|notes)"/)).not_to be_empty
    expect(queries.grep(/"(messages|notes|topics|aliases)"\.\*/)).to be_empty
    expect(queries.grep(/body/)).to be_empty
    expect(queries.grep_v(/api_tokens|SET LOCAL/).size).to eq(5)
  end

  it "writes nothing, marks nothing as read and is not publicly cacheable" do
    message_activity
    note_activity
    headers = bearer(user)
    stamps = -> { [ Activity.maximum(:updated_at), Activity.where(read_at: nil).count, Note.maximum(:updated_at) ] }
    before = stamps.call

    queries = captured_queries { get path, headers: headers }

    expect(response).to have_http_status(:ok)
    expect(data.map { |row| row["read_at"] }).to eq([ nil, nil ])
    expect(stamps.call).to eq(before)
    expect(queries.grep(/\A\s*(INSERT|UPDATE|DELETE)/i).grep_v(/api_tokens/)).to be_empty
    expect(response.headers["Vary"].to_s).to include("Authorization")
    expect(response.headers["Cache-Control"].to_s).not_to include("public")
  end
end
