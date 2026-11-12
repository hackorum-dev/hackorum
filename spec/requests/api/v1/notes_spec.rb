require "rails_helper"

RSpec.describe "API v1 notes", type: :request do
  let(:sender) { create(:alias, :with_sent_messages, name: "Alice A", email: "alice@example.org") }
  let(:topic) { create(:topic, creator_alias: sender, slug: "add-feature") }
  let(:author) { create(:user, username: "alice") }
  let(:mentioned) { create(:user, username: "bob") }
  let(:member) { create(:user, username: "carol") }
  let(:outsider) { create(:user, username: "dave") }
  let(:team) { create(:team, name: "reviewers") }
  let(:start) { Time.zone.parse("2026-03-01 10:00:00") }
  let(:note_keys) do
    %w[id topic_id message_id author body global tags mentions created_at updated_at edited last_editor]
  end

  before { create(:team_member, team: team, user: member) }

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

  def note(at: start, by: author, **attrs)
    create(:note, topic: topic, author: by, last_editor: by, created_at: at, updated_at: at, **attrs)
  end

  def mention(note, target)
    create(:note_mention, note: note, mentionable: target)
  end

  def notes_as(owner = nil, **params)
    get "/api/v1/topics/#{topic.id}/notes", params: params, headers: owner ? bearer(owner) : {}
    expect(response).to have_http_status(:ok)
    ids
  end

  describe "GET /topics/{id}/notes" do
    it "gives the documented row" do
      message = create(:message, topic: topic, sender: sender)
      own_alias = create(:alias, person: author.person, user: author, name: "Alice Author", email: "private@example.org")
      author.person.update!(default_alias_id: own_alias.id)
      shown = note(message: message, body: "Check <b>this</b> @bob @reviewers #todo\nsecond line")
      mention(shown, mentioned)
      mention(shown, team)
      create(:note_tag, note: shown, tag: "todo")
      create(:note_tag, note: shown, tag: "later")

      get "/api/v1/topics/#{topic.id}/notes", headers: bearer(author)

      expect(response).to have_http_status(:ok)
      expect(body.keys).to match_array(%w[data next_cursor])
      expect(body["next_cursor"]).to be_nil
      row = data.first
      expect(row.keys).to match_array(note_keys)
      expect(row).to eq(
        "id" => shown.id, "topic_id" => topic.id, "message_id" => message.id,
        "author" => { "name" => "Alice Author" },
        "body" => "Check <b>this</b> @bob @reviewers #todo\nsecond line", "global" => false,
        "tags" => %w[todo later],
        "mentions" => [ { "type" => "user", "name" => "bob" }, { "type" => "team", "name" => "reviewers" } ],
        "created_at" => "2026-03-01T10:00:00.000Z", "updated_at" => "2026-03-01T10:00:00.000Z",
        "edited" => false, "last_editor" => nil
      )
      expect(response.body).not_to include("private@example.org")
      expect(response.body).not_to include("example.org")
    end

    it "names the author as the site does" do
      plain = note(by: create(:user, username: "erin"), global: true)
      nameless = create(:user, username: nil)
      unnamed = note(at: start + 1.minute, by: nameless, global: true)
      gone = create(:user, username: nil, deleted_at: Time.current)
      deleted = note(at: start + 2.minutes, by: gone, global: true)

      expect(notes_as).to eq([ plain.id, unnamed.id, deleted.id ])

      expect(data.map { |row| row["author"] }).to eq([
        { "name" => "erin" }, { "name" => "User ##{nameless.id}" }, { "name" => "Deleted user" }
      ])
      helpers = ApplicationController.helpers
      expect(data.map { |row| row["author"]["name"] })
        .to eq([ plain, unnamed, deleted ].map { |row| helpers.display_name_for_user(row.author) })
    end

    it "shows a private note to its author, to a mentioned user and to a member of a mentioned team only" do
      own = note
      direct = note(at: start + 1.minute)
      mention(direct, mentioned)
      shared = note(at: start + 2.minutes)
      mention(shared, team)

      expect(notes_as(author)).to eq([ own.id, direct.id, shared.id ])
      expect(notes_as(mentioned)).to eq([ direct.id ])
      expect(notes_as(member)).to eq([ shared.id ])
      expect(notes_as(outsider)).to eq([])
      expect(notes_as).to eq([])
    end

    it "gives a display name only, never the username of an author or editor" do
      named = create(:user, username: "frank")
      own_alias = create(:alias, person: named.person, user: named, name: "Frank Writer")
      named.person.update!(default_alias_id: own_alias.id)
      editor = create(:user, username: "grace", admin: true)
      create(:alias, person: editor.person, user: editor, name: "Grace Admin")
        .then { |row| editor.person.update!(default_alias_id: row.id) }
      shown = note(by: named, global: true, body: "plain text")
      shown.update!(last_editor: editor)

      [ nil, outsider ].each do |caller|
        expect(notes_as(caller)).to eq([ shown.id ])
        expect(data.first["author"]).to eq("name" => "Frank Writer")
        expect(data.first["last_editor"]).to eq("name" => "Grace Admin")
        expect(response.body).not_to include("frank", "grace", "username")
      end
    end

    it "hides a private note from a user who left the mentioned team" do
      shared = note
      mention(shared, team)
      expect(notes_as(member)).to eq([ shared.id ])

      TeamMember.find_by!(team: team, user: member).destroy!

      expect(notes_as(member)).to eq([])
      expect(response.body).not_to include(shared.body)
    end

    it "hides a private note from a user whose mention an edit removed" do
      create(:team_member, team: team, user: author)
      create(:team_member, team: team, user: mentioned)
      shown = NoteBuilder.new(author: author).create!(topic: topic, body: "ask @bob about it")
      expect(notes_as(mentioned)).to eq([ shown.id ])

      NoteBuilder.new(author: author).update!(note: shown, body: "ask nobody about it")

      expect(notes_as(mentioned)).to eq([])
      expect(notes_as(mentioned, message_id: 1)).to eq([])
      expect(notes_as(author)).to eq([ shown.id ])
      expect(data.first["mentions"]).to eq([])
    end

    it "keeps a private note of a message from an outsider who filters on the message" do
      message = create(:message, topic: topic, sender: sender)
      hidden = note(message: message, body: "for bob only")
      mention(hidden, mentioned)
      open = note(at: start + 1.minute, message: message, global: true)

      [ outsider, nil ].each do |caller|
        expect(notes_as(caller, message_id: message.id)).to eq([ open.id ])
        expect(response.body).not_to include("for bob only")
      end
      expect(notes_as(mentioned, message_id: message.id)).to eq([ hidden.id, open.id ])
    end

    it "shows a global note to everyone" do
      open = note(global: true, body: "@global #committable")
      note(at: start + 1.minute)

      [ nil, outsider, mentioned, member ].each do |caller|
        expect(notes_as(caller)).to eq([ open.id ])
      end
      expect(notes_as(author).size).to eq(2)
    end

    it "shows a deleted note to no one" do
      private_note = note(deleted_at: Time.current)
      mention(private_note, mentioned)
      mention(private_note, team)
      note(at: start + 1.minute, global: true, deleted_at: Time.current)

      [ nil, author, mentioned, member, outsider ].each do |caller|
        expect(notes_as(caller)).to eq([])
      end
    end

    it "lists a note once however many ways the caller may see it" do
      create(:team_member, team: team, user: author)
      second = create(:team, name: "hackers")
      create(:team_member, team: second, user: author)
      shown = note(global: true)
      [ author, team, second ].each { |target| mention(shown, target) }

      expect(notes_as(author)).to eq([ shown.id ])
      expect(data.first["mentions"].size).to eq(3)
    end

    it "names a mentioned team to everyone who sees the note, as the site does" do
      shown = note
      mention(shown, mentioned)
      mention(shown, team)

      expect(notes_as(mentioned)).to eq([ shown.id ])

      expect(data.first["mentions"]).to eq([ { "type" => "user", "name" => "bob" },
                                             { "type" => "team", "name" => "reviewers" } ])
      labels = shown.note_mentions.order(:id).map { |row| ApplicationController.helpers.note_mention_label(row) }
      expect(data.first["mentions"].map { |row| "@#{row['name']}" }).to eq(labels)
      expect(response.body).not_to include("carol")
    end

    it "labels a mentioned user without a username as the site does" do
      nameless = create(:user, username: nil)
      shown = note
      mention(shown, nameless)

      notes_as(author)

      expect(data.first["mentions"]).to eq([ { "type" => "user", "name" => "User ##{nameless.id}" } ])
    end

    it "says when the body was changed and names an editor who is not the author" do
      admin = create(:user, username: "root", admin: true)
      untouched = note(global: true)
      own = note(at: start + 1.minute, global: true, body: "first")
      own.note_edits.create!(editor: author, body: "first")
      moderated = note(at: start + 2.minutes, global: true)
      moderated.note_edits.create!(editor: admin, body: "before")
      moderated.update!(last_editor: admin)

      expect(notes_as(outsider)).to eq([ untouched.id, own.id, moderated.id ])

      expect(data.map { |row| row["edited"] }).to eq([ false, true, true ])
      expect(data.map { |row| row["last_editor"] }).to eq([ nil, nil, { "name" => "root" } ])
      expect(response.body).not_to include("before")
      expect(data.flat_map(&:keys).grep(/edits|history/)).to be_empty
    end

    it "takes the thread-level notes and the notes of a message, in order" do
      message = create(:message, topic: topic, sender: sender)
      other = create(:message, topic: topic, sender: sender)
      late = note(at: start + 2.hours, global: true)
      tied = Array.new(2) { note(at: start + 1.hour, global: true, message: message) }
      first = note(global: true, message: other)

      expect(notes_as).to eq([ first.id, *tied.map(&:id), late.id ])
      expect(data.map { |row| row["message_id"] }).to eq([ other.id, message.id, message.id, nil ])

      expect(notes_as(message_id: message.id)).to eq(tied.map(&:id))
      expect(notes_as(author, message_id: other.id)).to eq([ first.id ])
    end

    it "gives an empty list for a message of another topic or of none" do
      elsewhere = create(:topic, creator_alias: sender)
      foreign = create(:message, topic: elsewhere, sender: sender)
      create(:note, topic: elsewhere, author: author, message: foreign, global: true)
      note(global: true)

      expect(notes_as(message_id: foreign.id)).to eq([])
      expect(notes_as(message_id: 999_999_999)).to eq([])
      expect(notes_as(message_id: "99999999999999999999999999")).to eq([])
      expect(body).to eq("data" => [], "next_cursor" => nil)
    end

    it "rejects a malformed message_id and an unknown parameter" do
      [ "abc", "1.5", "-1", "12abc", "1 2" ].each do |value|
        get "/api/v1/topics/#{topic.id}/notes", params: { message_id: value }
        expect(response).to have_http_status(:bad_request), value
        expect(error_code).to eq("invalid_parameter"), value
      end

      get "/api/v1/topics/#{topic.id}/notes?message_id[]=1"
      expect(error_code).to eq("invalid_parameter")

      get "/api/v1/topics/#{topic.id}/notes", params: { author: "alice" }
      expect(error_code).to eq("invalid_parameter")
    end

    it "finds the topic by slug, answers an unknown one with 404 and a merged one with 301" do
      note(global: true)

      get "/api/v1/topics/add-feature/notes"
      expect(response).to have_http_status(:ok)
      expect(data.size).to eq(1)

      get "/api/v1/topics/nope/notes"
      expect(response).to have_http_status(:not_found)
      expect(error_code).to eq("not_found")

      source = create(:topic, creator_alias: sender, merged_into_topic_id: topic.id)
      get "/api/v1/topics/#{source.id}/notes?limit=2", headers: bearer(author)
      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers["Location"]).to end_with("/api/v1/topics/#{topic.id}/notes?limit=2")
    end

    it "pages through the visible notes without gaps or repeats" do
      create(:team_member, team: team, user: mentioned)
      expected = Array.new(5) do |i|
        row = note(at: start + (i / 2).hours, global: i.even?)
        mention(row, mentioned)
        mention(row, team)
        row.id
      end
      note(at: start + 30.minutes)
      headers = bearer(mentioned)

      seen = []
      cursor = nil
      3.times do
        get "/api/v1/topics/#{topic.id}/notes", params: { limit: 2, cursor: cursor }.compact, headers: headers
        expect(response).to have_http_status(:ok)
        seen.concat(ids)
        cursor = body["next_cursor"]
      end

      expect(seen).to eq(expected)
      expect(cursor).to be_nil
    end

    it "ties a cursor to its caller, its topic and its filter" do
      message = create(:message, topic: topic, sender: sender)
      2.times { |i| note(at: start + i.minutes, global: true, message: message) }
      other_topic = create(:topic, creator_alias: sender)
      path = "/api/v1/topics/#{topic.id}/notes"
      own = bearer(author)

      get path, params: { limit: 1 }, headers: own
      cursor = body["next_cursor"]
      expect(cursor).to be_present
      get path, params: { limit: 1 }
      anonymous = body["next_cursor"]

      get path, params: { limit: 2, cursor: cursor }, headers: bearer(author)
      expect(response).to have_http_status(:ok)
      expect(data.size).to eq(1)
      get path, params: { limit: 1, cursor: anonymous }
      expect(response).to have_http_status(:ok)

      [
        [ path, { cursor: cursor }, {} ],
        [ path, { cursor: cursor }, bearer(outsider) ],
        [ path, { cursor: anonymous }, own ],
        [ path, { cursor: cursor, message_id: message.id }, own ],
        [ "/api/v1/topics/#{other_topic.id}/notes", { cursor: cursor }, own ]
      ].each do |url, params, headers|
        get url, params: params, headers: headers
        expect(response).to have_http_status(:bad_request)
        expect(error_code).to eq("invalid_cursor")
      end
    end

    it "runs the same queries for one note and for three" do
      build = lambda do |at|
        row = note(at: at, by: create(:user), global: true)
        row.update!(last_editor: create(:user, admin: true))
        row.note_edits.create!(editor: row.last_editor, body: "old")
        mention(row, create(:user))
        mention(row, create(:team))
        create(:note_tag, note: row, tag: "todo")
        create(:note_tag, note: row, tag: "later")
      end
      headers = bearer(outsider)
      get "/api/v1/me", headers: headers
      build.call(start)
      one = captured_queries { get "/api/v1/topics/#{topic.id}/notes", headers: headers }
      expect(data.size).to eq(1)

      2.times { |i| build.call(start + (i + 1).hours) }
      three = captured_queries { get "/api/v1/topics/#{topic.id}/notes", headers: headers }

      expect(data.size).to eq(3)
      expect(data.map { |row| [ row["tags"].size, row["mentions"].size, row["edited"] ] }).to all(eq([ 2, 2, true ]))
      expect(three.size).to eq(one.size)
    end

    it "writes nothing and is not publicly cacheable" do
      shown = note
      mention(shown, mentioned)
      create(:activity, user: mentioned, subject: shown, read_at: nil)
      headers = bearer(mentioned)
      stamps = -> { [ Note.maximum(:updated_at), Activity.maximum(:updated_at), Activity.where(read_at: nil).count ] }
      before = stamps.call

      queries = captured_queries { get "/api/v1/topics/#{topic.id}/notes", headers: headers }

      expect(response).to have_http_status(:ok)
      expect(ids).to eq([ shown.id ])
      expect(stamps.call).to eq(before)
      expect(queries.grep(/\A\s*(INSERT|UPDATE|DELETE)/i).grep_v(/api_tokens/)).to be_empty
      expect(response.headers["Vary"].to_s).to include("Authorization")
      expect(response.headers["Cache-Control"].to_s).not_to include("public")
    end
  end
end
