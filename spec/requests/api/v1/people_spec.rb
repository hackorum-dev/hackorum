require "rails_helper"

RSpec.describe "API v1 /people", type: :request do
  let(:person) { create(:person) }
  let!(:main) do
    create(:alias, :with_sent_messages, person: person, name: "Alice A", email: "alice.a@example.org")
  end

  def body
    JSON.parse(response.body)
  end

  def error_code
    body.dig("error", "code")
  end

  it "returns a person without a token" do
    get "/api/v1/people/alice.a@example.org"

    expect(response).to have_http_status(:ok)
    expect(response.headers["RateLimit-Limit"]).to be_present
    expect(body.keys).to match_array(%w[id name email url html_url aliases contributor_type contributor_badge stats])
    expect(body).to include("id" => person.id, "name" => "Alice A", "email" => "alice.a@example.org",
                            "contributor_type" => nil, "contributor_badge" => nil)
    expect(body["url"]).to end_with("/api/v1/people/alice.a%40example.org")
    expect(body["html_url"]).to end_with("/person/alice.a@example.org")
    expect(body["aliases"]).to eq([ { "name" => "Alice A", "email" => "alice.a@example.org" } ])
    expect(body["stats"]).to eq(
      "messages_sent" => 0, "messages_sent_hidden" => 0,
      "threads_started" => 0, "threads_started_hidden" => 0,
      "threads_joined" => 0, "threads_joined_hidden" => 0,
      "patches_sent" => 0, "patch_threads" => 0,
      "first_message_at" => nil, "last_message_at" => nil
    )
  end

  it "finds the email in any case and percent-encoded" do
    get "/api/v1/people/ALICE.A@Example.ORG"
    expect(response).to have_http_status(:ok)
    expect(body["id"]).to eq(person.id)

    get "/api/v1/people/alice.a%40example.org"
    expect(response).to have_http_status(:ok)
    expect(body["id"]).to eq(person.id)
  end

  it "answers an unknown email with a JSON 404" do
    get "/api/v1/people/nobody@example.org"

    expect(response).to have_http_status(:not_found)
    expect(response.media_type).to eq("application/json")
    expect(error_code).to eq("not_found")
  end

  it "answers an email with a NUL byte with a 404" do
    get "/api/v1/people/a%00b"

    expect(response).to have_http_status(:not_found)
    expect(error_code).to eq("not_found")
  end

  it "shows a person without a default alias" do
    create(:alias, :mention_only, person: person, name: "Mentioned", email: "aaa@example.org")
    person.update_columns(default_alias_id: nil)

    get "/api/v1/people/alice.a@example.org"

    expect(response).to have_http_status(:ok)
    expect(body).to include("name" => "Alice A", "email" => "alice.a@example.org")
    expect(body["url"]).to end_with("/api/v1/people/alice.a%40example.org")
    expect(body["html_url"]).to end_with("/person/alice.a@example.org")
  end

  it "does not look people up by id" do
    get "/api/v1/people/#{person.id}"

    expect(response).to have_http_status(:not_found)
    expect(error_code).to eq("not_found")
  end

  it "resolves the email of a merged person to the target" do
    old = create(:alias, :with_sent_messages, person: create(:person), name: "Old Alice", email: "old@example.org")
    person.attach_alias!(old)

    get "/api/v1/people/old@example.org"

    expect(response).to have_http_status(:ok)
    expect(body).to include("id" => person.id, "email" => "alice.a@example.org")
    expect(body["aliases"].map { |row| row["email"] }).to eq([ "alice.a@example.org", "old@example.org" ])
  end

  it "lists sending aliases by email and leaves mention-only ones out" do
    create(:alias, :with_sent_messages, person: person, name: "A. Alice", email: "aa@example.org")
    create(:alias, :mention_only, person: person, name: "Mentioned", email: "mentioned@example.org")

    get "/api/v1/people/alice.a@example.org"

    expect(body["aliases"]).to eq([
      { "name" => "A. Alice", "email" => "aa@example.org" },
      { "name" => "Alice A", "email" => "alice.a@example.org" }
    ])
  end

  it "gives the highest contributor type" do
    ContributorMembership.create!(person: person, contributor_type: "major_contributor")
    ContributorMembership.create!(person: person, contributor_type: "committer")

    get "/api/v1/people/alice.a@example.org"

    expect(body).to include("contributor_type" => "committer", "contributor_badge" => "Committer")
  end

  it "counts hidden lists apart" do
    other = create(:alias, person: create(:person), email: "other@example.org")
    shown = create(:topic, creator_alias: main, created_at: 5.days.ago)
    hidden = create(:topic, creator_alias: main, created_at: 4.days.ago, hidden_by_default: true)
    foreign = create(:topic, creator_alias: other, created_at: 6.days.ago)
    first_at = Time.zone.parse("2026-01-02 03:04:05")
    last_at = Time.zone.parse("2026-02-03 04:05:06")
    create(:message, topic: shown, sender: main, created_at: first_at)
    create(:message, topic: shown, sender: main, created_at: last_at, is_patch_submission: true)
    create(:message, topic: foreign, sender: main, created_at: first_at + 1.day, is_patch_submission: true)
    create(:message, topic: hidden, sender: main, created_at: first_at + 2.days)

    get "/api/v1/people/alice.a@example.org"

    expect(body["stats"]).to eq(
      "messages_sent" => 3, "messages_sent_hidden" => 1,
      "threads_started" => 1, "threads_started_hidden" => 1,
      "threads_joined" => 2, "threads_joined_hidden" => 1,
      "patches_sent" => 2, "patch_threads" => 2,
      "first_message_at" => "2026-01-02T03:04:05.000Z", "last_message_at" => "2026-02-03T04:05:06.000Z"
    )
  end

  it "leaves private fields out" do
    user = create(:user, username: "alice")
    main.update!(user: user, verified_at: Time.current)

    get "/api/v1/people/alice.a@example.org"

    expect(response.body).not_to include("username", "verified_at", "teams", "affiliation")
  end

  it "runs the same queries for one alias and for three" do
    one = captured_queries { get "/api/v1/people/alice.a@example.org" }
    create(:alias, :with_sent_messages, person: person, email: "b@example.org")
    create(:alias, :with_sent_messages, person: person, email: "c@example.org")
    three = captured_queries { get "/api/v1/people/alice.a@example.org" }

    expect(body["aliases"].size).to eq(3)
    expect(three.size).to eq(one.size)
  end

  it "does not write" do
    queries = captured_queries { get "/api/v1/people/alice.a@example.org" }

    expect(queries.grep(/\A\s*(INSERT|UPDATE|DELETE)/i)).to be_empty
  end

  describe "GET /people/{email}/topics" do
    let(:bob) { create(:alias, :with_sent_messages, name: "Bob B", email: "bob@example.org") }
    let(:start) { Time.zone.parse("2026-03-01 10:00:00") }
    let(:brief_keys) do
      %w[id slug title url html_url created_at last_message_at message_count participant_count
         contributor_participant_count highest_contributor_type has_attachments commit_count last_commit_at
         creator last_sender mailing_lists commitfest ci me]
    end

    def data
      body["data"]
    end

    def ids
      data.map { |row| row["id"] }
    end

    def thread(creator: main, **attrs)
      create(:topic, creator_alias: creator, **attrs)
    end

    def post_in(topic, at, sender: main)
      create(:message, topic: topic, sender: sender, created_at: at)
    end

    it "lists the topics the person took part in, last active first, with the participation" do
      own = thread(title: "Mine")
      joined = thread(creator: bob, title: "Joined")
      foreign = thread(creator: bob)
      post_in(own, start)
      post_in(own, start + 2.hours)
      post_in(own, start + 9.hours, sender: bob)
      post_in(joined, start + 1.hour, sender: bob)
      post_in(joined, start + 3.hours)
      post_in(foreign, start + 4.hours, sender: bob)
      list = create(:mailing_list, identifier: "pgsql-hackers", display_name: "pgsql-hackers")
      create(:topic_mailing_list, topic: joined, mailing_list: list)

      get "/api/v1/people/alice.a@example.org/topics"

      expect(response).to have_http_status(:ok)
      expect(response.headers["RateLimit-Limit"]).to be_present
      expect(body.keys).to match_array(%w[data next_cursor])
      expect(body["next_cursor"]).to be_nil
      expect(ids).to eq([ joined.id, own.id ])
      expect(data.first.keys).to match_array(brief_keys + %w[participation])
      expect(data.first).to include("title" => "Joined", "message_count" => 2)
      expect(data.first["creator"]).to include("id" => bob.person_id)
      expect(data.first["mailing_lists"]).to eq([ { "identifier" => "pgsql-hackers", "display_name" => "pgsql-hackers" } ])
      expect(data.first["participation"]).to eq(
        "message_count" => 1, "first_message_at" => "2026-03-01T13:00:00.000Z",
        "last_message_at" => "2026-03-01T13:00:00.000Z", "started" => false
      )
      expect(data.last["participation"]).to eq(
        "message_count" => 2, "first_message_at" => "2026-03-01T10:00:00.000Z",
        "last_message_at" => "2026-03-01T12:00:00.000Z", "started" => true
      )
    end

    it "leaves out merged and hidden-list topics" do
      shown = thread
      post_in(shown, start)
      post_in(thread(hidden_by_default: true), start + 1.hour)
      post_in(thread(merged_into_topic_id: shown.id), start + 2.hours)

      get "/api/v1/people/alice.a@example.org/topics"

      expect(ids).to eq([ shown.id ])
    end

    it "answers an unknown email and a NUL with 404" do
      get "/api/v1/people/nobody@example.org/topics"
      expect(response).to have_http_status(:not_found)
      expect(error_code).to eq("not_found")

      get "/api/v1/people/a%00b/topics"
      expect(response).to have_http_status(:not_found)
    end

    it "gives an empty page to a person without messages, by a percent-encoded address" do
      get "/api/v1/people/alice.a%40example.org/topics"

      expect(body).to eq("data" => [], "next_cursor" => nil)
    end

    it "pages through ties and rejects a bad cursor" do
      tied = Array.new(3) { thread.tap { |topic| post_in(topic, start + 1.hour) } }
      older = thread.tap { |topic| post_in(topic, start) }

      get "/api/v1/people/alice.a@example.org/topics", params: { limit: 2 }
      expect(ids).to eq([ tied[2].id, tied[1].id ])

      get "/api/v1/people/alice.a@example.org/topics", params: { limit: 2, cursor: body["next_cursor"] }
      expect(ids).to eq([ tied[0].id, older.id ])
      expect(body["next_cursor"]).to be_nil

      get "/api/v1/people/alice.a@example.org/topics", params: { cursor: "nope" }
      expect(response).to have_http_status(:bad_request)
      expect(error_code).to eq("invalid_cursor")
    end

    it "runs the same queries for one row and for three, and does not write" do
      list = create(:mailing_list)
      decorated = lambda do |at|
        topic = thread(creator: create(:alias, :with_sent_messages))
        post_in(topic, at)
        post_in(topic, at + 1.minute, sender: create(:alias, :with_sent_messages))
        create(:topic_mailing_list, topic: topic, mailing_list: list)
      end
      decorated.call(start)
      one = captured_queries { get "/api/v1/people/alice.a@example.org/topics" }
      expect(data.size).to eq(1)

      2.times { |i| decorated.call(start + (i + 1).hours) }
      three = captured_queries { get "/api/v1/people/alice.a@example.org/topics" }

      expect(data.size).to eq(3)
      expect(three.size).to eq(one.size)
      expect(three.grep(/\A\s*(INSERT|UPDATE|DELETE)/i)).to be_empty
    end
  end
end
