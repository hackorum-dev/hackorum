require "rails_helper"

RSpec.describe "API v1 per-user thread state", type: :request do
  let(:sender) { create(:alias, :with_sent_messages, name: "Alice A", email: "alice@example.org") }
  let(:user) { create(:user, username: "alice") }
  let(:other) { create(:user, username: "bob") }
  let(:headers) { bearer(user) }
  let(:me_keys) { %w[starred ignored status read_count unread_count note_count] }

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

  def row(topic)
    data.find { |entry| entry["id"] == topic.id }
  end

  def thread(messages: 3, at: 2.days.ago, **attrs)
    topic = create(:topic, creator_alias: sender, **attrs)
    Array.new(messages) { |i| create(:message, topic: topic, sender: sender, created_at: at + i.minutes) }
    topic.reload
  end

  def message_ids(topic)
    topic.messages.order(:created_at, :id).pluck(:id)
  end

  def read(topic, first, last = first, by: user)
    ids = message_ids(topic)
    MessageReadRange.add_range(user: by, topic: topic, start_id: ids[first], end_id: ids[last])
  end

  def aware(topic, by: user)
    ThreadAwareness.mark_until(user: by, topic: topic, until_message_id: topic.last_message_id)
  end

  def without_me(value)
    case value
    when Hash then value.except("me").transform_values { |child| without_me(child) }
    when Array then value.map { |child| without_me(child) }
    else value
    end
  end

  describe "me on GET /topics" do
    it "is null without a token" do
      topic = thread
      read(topic, 0)
      create(:topic_star, user: user, topic: topic)

      get "/api/v1/topics"

      expect(data.first).to have_key("me")
      expect(data.first["me"]).to be_nil
    end

    it "is the caller's state with a token" do
      topic = thread
      fresh = thread(at: 1.day.ago)
      read(topic, 0, 1)
      aware(topic)
      create(:topic_star, user: user, topic: topic)
      create(:note, topic: topic, author: user)
      create(:note, topic: topic, author: other, global: true)
      create(:note, topic: topic, author: other)

      get "/api/v1/topics", headers: headers

      expect(response).to have_http_status(:ok)
      expect(ids).to eq([ fresh.id, topic.id ])
      expect(row(topic)["me"]).to eq("starred" => true, "ignored" => false, "status" => "reading",
                                     "read_count" => 2, "unread_count" => 1, "note_count" => 2)
      expect(row(fresh)["me"]).to eq("starred" => false, "ignored" => false, "status" => "new",
                                     "read_count" => 0, "unread_count" => 3, "note_count" => 0)
    end

    it "goes through new, aware, reading and read" do
      topics = Array.new(4) { |i| thread(at: (i + 1).days.ago) }
      aware(topics[1])
      read(topics[2], 2)
      read(topics[3], 0, 2)

      get "/api/v1/topics", headers: headers

      expect(topics.map { |topic| row(topic)["me"]["status"] }).to eq(%w[new aware reading read])
      expect(topics.map { |topic| row(topic)["me"]["unread_count"] }).to eq([ 3, 3, 2, 0 ])
    end

    it "never shows another user's state" do
      topic = thread
      read(topic, 0, 2, by: other)
      aware(topic, by: other)
      create(:topic_star, user: other, topic: topic)
      create(:topic_ignore, user: other, topic: topic)
      create(:note, topic: topic, author: other)
      team = create(:team)
      create(:team_member, team: team, user: user)
      create(:team_member, team: team, user: other)

      get "/api/v1/topics", headers: headers

      expect(row(topic)["me"]).to eq("starred" => false, "ignored" => false, "status" => "new",
                                     "read_count" => 0, "unread_count" => 3, "note_count" => 0)
      expect(row(topic)["me"].keys).to match_array(me_keys)
      expect(row(topic).keys.grep(/team|reader|participation/)).to be_empty

      get "/api/v1/topics", headers: bearer(other)
      expect(row(topic)["me"]).to include("starred" => true, "ignored" => true, "status" => "read", "note_count" => 1)
    end

    it "answers a user without state as it answers anyone, apart from me" do
      create(:patch_ci_repo_state)
      topic = thread(slug: "plain")
      create(:topic_mailing_list, topic: topic, mailing_list: create(:mailing_list))
      thread(at: 3.days.ago)
      read(topic, 0, by: other)
      create(:topic_ignore, user: other, topic: topic)
      user

      [ "/api/v1/topics", "/api/v1/topics?q=discussion", "/api/v1/topics?sort=created&limit=1",
        "/api/v1/topics/#{topic.id}", "/api/v1/topics/plain", "/api/v1/people/alice@example.org/topics" ].each do |path|
        get path
        anonymous = body
        get path, headers: headers
        signed_in = body

        expect(response).to have_http_status(:ok), path
        if path.include?("limit=1")
          cursors = [ anonymous, signed_in ].map { |answer| answer.delete("next_cursor") }
          expect(cursors.uniq.size).to eq(2)
        end
        expect(without_me(signed_in)).to eq(without_me(anonymous)), path
        rows = anonymous["data"] || [ anonymous ]
        expect(rows).not_to be_empty, path
        expect(rows.map { |entry| entry.fetch("me") }).to all(be_nil), path
        expect((signed_in["data"] || [ signed_in ]).map { |entry| entry.fetch("me") }).to all(be_a(Hash)), path
      end
    end

    it "runs the same queries for one row and for three, five of them for me" do
      first = thread
      read(first, 0)
      create(:topic_star, user: user, topic: first)
      create(:note, topic: first, author: user)
      headers
      anonymous = captured_queries { get "/api/v1/topics" }
      one = captured_queries { get "/api/v1/topics", headers: headers }
      expect(data.size).to eq(1)

      2.times do |i|
        topic = thread(at: (i + 3).days.ago)
        read(topic, 1)
        aware(topic)
        create(:topic_ignore, user: user, topic: topic)
        create(:topic_star, user: user, topic: topic)
        create(:note, topic: topic, author: user)
      end
      three = captured_queries { get "/api/v1/topics", headers: headers }

      expect(data.size).to eq(3)
      expect(data.map { |entry| entry["me"]["note_count"] }).to eq([ 1, 1, 1 ])
      one, three = [ one, three ].map { |queries| queries.grep_v(/api_tokens|FROM "users"/) }
      expect(three.size).to eq(one.size)
      expect(one.size - anonymous.size).to eq(5)
    end
  end

  describe "the ignore filter on GET /topics" do
    let!(:plain) { thread(at: 4.days.ago, title: "vacuum plain") }
    let!(:ignored) { thread(at: 3.days.ago, title: "vacuum ignored") }
    let!(:kept) { thread(at: 2.days.ago, title: "vacuum ignored and starred") }

    before do
      create(:topic_ignore, user: user, topic: ignored)
      create(:topic_ignore, user: user, topic: kept)
      create(:topic_star, user: user, topic: kept)
    end

    it "hides ignored topics from their owner only, starred ones stay" do
      get "/api/v1/topics", headers: headers
      expect(ids).to eq([ kept.id, plain.id ])
      expect(row(kept)["me"]).to include("starred" => true, "ignored" => true)

      get "/api/v1/topics"
      expect(ids).to eq([ kept.id, ignored.id, plain.id ])

      get "/api/v1/topics", headers: bearer(other)
      expect(ids).to eq([ kept.id, ignored.id, plain.id ])
      expect(data.map { |entry| entry["me"]["ignored"] }).to eq([ false, false, false ])
    end

    it "applies with list, author and sort" do
      list = create(:mailing_list, identifier: "pgsql-hackers")
      [ plain, ignored, kept ].each { |topic| create(:topic_mailing_list, topic: topic, mailing_list: list) }

      [ { list: "pgsql-hackers" }, { author: "alice@example.org" }, { sort: "created" } ].each do |params|
        get "/api/v1/topics", params: params, headers: headers
        expect(ids).to match_array([ kept.id, plain.id ]), params.inspect

        get "/api/v1/topics", params: params
        expect(ids).to match_array([ kept.id, ignored.id, plain.id ]), params.inspect
      end
    end

    it "applies to a search, unless the query has an ignored: selector" do
      get "/api/v1/topics", params: { q: "title:vacuum" }, headers: headers
      expect(ids).to eq([ kept.id, plain.id ])

      get "/api/v1/topics", params: { q: "title:vacuum" }
      expect(ids).to eq([ kept.id, ignored.id, plain.id ])

      get "/api/v1/topics", params: { q: "ignored:me" }, headers: headers
      expect(ids).to eq([ kept.id, ignored.id ])
      expect(body["warnings"]).to eq([])
      expect(row(ignored)["me"]).to include("ignored" => true, "starred" => false)

      get "/api/v1/topics", params: { q: "title:vacuum -ignored:me" }, headers: headers
      expect(ids).to eq([ plain.id ])

      get "/api/v1/topics", params: { q: "ignored:me" }, headers: bearer(other)
      expect(ids).to eq([])
    end

    it "does not apply to a person's topics" do
      get "/api/v1/people/alice@example.org/topics", headers: headers

      expect(ids).to eq([ kept.id, ignored.id, plain.id ])
      expect(row(ignored)["me"]).to include("ignored" => true, "status" => "new", "unread_count" => 3)
      expect(row(ignored)["me"].keys).to match_array(me_keys)
      expect(row(ignored)).to have_key("participation")

      get "/api/v1/people/alice@example.org/topics"
      expect(data.map { |entry| entry.fetch("me") }).to eq([ nil, nil, nil ])
    end
  end

  describe "searching as the caller" do
    it "takes starred:me, unread:me and from:me with a token and warns without one" do
      own_alias = create(:alias, :with_sent_messages, person: user.person, user: user, email: "me@example.org")
      starred = thread(at: 4.days.ago)
      done = thread(at: 3.days.ago)
      mine = create(:topic, creator_alias: own_alias)
      create(:message, topic: mine, sender: own_alias, created_at: 1.day.ago)
      create(:topic_star, user: user, topic: starred)
      create(:topic_star, user: other, topic: done)
      read(done, 0, 2)
      read(mine, 0)
      read(starred, 0, 2, by: other)

      get "/api/v1/topics", params: { q: "starred:me" }, headers: headers
      expect(ids).to eq([ starred.id ])
      expect(body["warnings"]).to eq([])
      expect(data.first["me"]).to include("starred" => true)

      get "/api/v1/topics", params: { q: "unread:me" }, headers: headers
      expect(ids).to eq([ starred.id ])

      get "/api/v1/topics", params: { q: "read:me" }, headers: headers
      expect(ids).to eq([ mine.id, done.id ])

      get "/api/v1/topics", params: { q: "from:me" }, headers: headers
      expect(ids).to eq([ mine.id ])
      expect(body["warnings"]).to eq([])

      %w[starred:me unread:me from:me].each do |q|
        get "/api/v1/topics", params: { q: q }
        expect(response).to have_http_status(:ok), q
        expect(data).to eq([]), q
        expect(body["warnings"]).to include("Must be signed in to use 'me'"), q
      end
    end

    it "takes a team name in a state selector from a member only" do
      team = create(:team, name: "reviewers")
      mate = create(:user, username: "carol")
      create(:team_member, team: team, user: user)
      create(:team_member, team: team, user: mate)
      topic = thread
      create(:topic_star, user: mate, topic: topic)

      get "/api/v1/topics", params: { q: "starred:reviewers" }, headers: headers
      expect(ids).to eq([ topic.id ])
      expect(data.first["me"]).to include("starred" => false)
      expect(data.first["me"].keys).to match_array(me_keys)
      keys = data.first.to_json.scan(/"(\w+)":/).flatten.uniq
      expect(keys).to include("me", "creator")
      expect(keys.grep(/team|starr(ed_by|ers?)\z|reader|member|users?\z/)).to be_empty

      [ bearer(other), {} ].each do |outsider|
        get "/api/v1/topics", params: { q: "starred:reviewers" }, headers: outsider
        expect(ids).to eq([])
        expect(body["warnings"]).to include("Invalid state subject: reviewers")
      end
    end

    it "finds private notes of the caller only" do
      topic = thread
      secret = thread(at: 3.days.ago)
      create(:note_tag, note: create(:note, topic: topic, author: user), tag: "todo")
      create(:note_tag, note: create(:note, topic: secret, author: other), tag: "todo")

      get "/api/v1/topics", params: { q: "tag:todo" }, headers: headers
      expect(ids).to eq([ topic.id ])

      get "/api/v1/topics", params: { q: "tag:todo[from:bob]" }, headers: headers
      expect(ids).to eq([])

      get "/api/v1/topics", params: { q: "notes:me" }, headers: headers
      expect(ids).to eq([ topic.id ])

      get "/api/v1/topics", params: { q: "tag:todo" }
      expect(ids).to eq([])
    end
  end

  describe "cursors" do
    before { 3.times { |i| thread(at: (i + 2).days.ago) } }

    def cursor_for(headers = {}, **params)
      get "/api/v1/topics", params: { limit: 1, **params }, headers: headers
      expect(response).to have_http_status(:ok)
      body["next_cursor"]
    end

    def error_code
      body.dig("error", "code")
    end

    it "belong to the caller on the topic list" do
      own = cursor_for(headers)
      anonymous = cursor_for
      foreign = cursor_for(bearer(other))

      get "/api/v1/topics", params: { limit: 1, cursor: own }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(data.size).to eq(1)

      get "/api/v1/topics", params: { limit: 1, cursor: own }, headers: bearer(user)
      expect(response).to have_http_status(:ok)

      get "/api/v1/topics", params: { limit: 1, cursor: anonymous }
      expect(response).to have_http_status(:ok)

      [ [ anonymous, headers ], [ own, {} ], [ foreign, headers ], [ own, bearer(other) ] ].each do |cursor, caller|
        get "/api/v1/topics", params: { limit: 1, cursor: cursor }, headers: caller
        expect(response).to have_http_status(:bad_request)
        expect(error_code).to eq("invalid_cursor")
      end
    end

    it "belong to the caller on a search too" do
      cursor = cursor_for(headers, q: "discussion")

      get "/api/v1/topics", params: { limit: 1, q: "discussion", cursor: cursor }, headers: headers
      expect(response).to have_http_status(:ok)

      get "/api/v1/topics", params: { limit: 1, q: "discussion", cursor: cursor }
      expect(error_code).to eq("invalid_cursor")
    end

    it "pages the filtered list without gaps when a topic is ignored" do
      create(:topic_ignore, user: user, topic: Topic.order(:last_message_at).second)
      expected = Topic.order(last_message_at: :desc).pluck(:id).values_at(0, 2)

      seen = []
      cursor = nil
      2.times do
        get "/api/v1/topics", params: { limit: 1, cursor: cursor }.compact, headers: headers
        seen.concat(ids)
        cursor = body["next_cursor"]
      end

      expect(seen).to eq(expected)
      expect(cursor).to be_nil
    end

    it "do not belong to a caller where the rows are the same for everyone" do
      get "/api/v1/people/alice@example.org/topics", params: { limit: 1 }
      cursor = body["next_cursor"]
      expect(cursor).to be_present

      get "/api/v1/people/alice@example.org/topics", params: { limit: 1, cursor: cursor }, headers: headers
      expect(response).to have_http_status(:ok)
      expect(data.first["me"]).to be_a(Hash)
    end
  end

  describe "me on GET /topics/{id}" do
    it "is null without a token" do
      topic = thread

      get "/api/v1/topics/#{topic.id}"

      expect(body).to have_key("me")
      expect(body["me"]).to be_nil
    end

    it "has the list state and the first unread message" do
      topic = thread(messages: 4)
      read(topic, 0, 1)
      read(topic, 3)
      read(topic, 0, 3, by: other)
      create(:topic_ignore, user: user, topic: topic)

      get "/api/v1/topics/#{topic.id}", headers: headers

      expect(response).to have_http_status(:ok)
      expect(body["me"]).to eq(
        "starred" => false, "ignored" => true, "status" => "reading", "read_count" => 3, "unread_count" => 1,
        "note_count" => 0, "first_unread_message_id" => message_ids(topic)[2]
      )

      get "/api/v1/topics/#{topic.id}", headers: bearer(other)
      expect(body["me"]).to include("status" => "read", "ignored" => false, "unread_count" => 0,
                                    "first_unread_message_id" => nil)
    end

    it "starts at the first message for a caller who read nothing" do
      topic = thread

      get "/api/v1/topics/#{topic.id}", headers: headers

      expect(body["me"]).to include("status" => "new", "first_unread_message_id" => message_ids(topic).first)
    end

    it "gives null for a topic without messages" do
      topic = create(:topic, creator_alias: sender)

      get "/api/v1/topics/#{topic.id}", headers: headers

      expect(body["me"]).to include("status" => "new", "unread_count" => 0, "first_unread_message_id" => nil)
    end

    it "adds six queries with a token, and two for the features of the account" do
      topic = thread
      headers
      anonymous = captured_queries { get "/api/v1/topics/#{topic.id}" }
      signed_in = captured_queries { get "/api/v1/topics/#{topic.id}", headers: headers }

      token_queries = signed_in.grep(/api_tokens|FROM "users"/).size
      feature_queries = signed_in.grep(/"user_features"|"team_features"/).size
      expect(feature_queries).to eq(2)
      expect(signed_in.size - token_queries - feature_queries - anonymous.size).to eq(6)
    end
  end

  it "writes nothing, also where the site marks a thread as seen" do
    topic = thread(slug: "quiet")
    seen = thread(at: 3.days.ago)
    read(seen, 0)
    aware(seen)
    counts = -> { [ ThreadAwareness.count, MessageReadRange.count, TopicStar.count, TopicIgnore.count ] }
    before = counts.call
    stamps = [ ThreadAwareness.maximum(:updated_at), MessageReadRange.maximum(:updated_at) ]
    headers

    queries = captured_queries do
      [ "/api/v1/topics", "/api/v1/topics?q=unread:me", "/api/v1/topics/#{topic.id}", "/api/v1/topics/quiet",
        "/api/v1/topics/#{seen.id}", "/api/v1/people/alice@example.org/topics" ].each do |path|
        get path, headers: headers
        expect(response).to have_http_status(:ok), path
      end
    end

    expect(counts.call).to eq(before)
    expect([ ThreadAwareness.maximum(:updated_at), MessageReadRange.maximum(:updated_at) ]).to eq(stamps)
    expect(queries.grep(/\A\s*(INSERT|UPDATE|DELETE)/i).grep_v(/api_tokens/)).to be_empty
  end

  describe "Vary and caching" do
    around do |example|
      limits = Rails.configuration.x.api_rate_limit
      old_store = Rack::Attack.cache.store
      old_limits = [ limits.anonymous, limits.token ]
      Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
      example.run
    ensure
      Rack::Attack.cache.store = old_store
      limits.anonymous, limits.token = old_limits
    end

    def vary
      response.headers["Vary"].to_s.split(/\s*,\s*/)
    end

    it "sends Vary: Authorization on every answer, errors included" do
      topic = thread

      requests = {
        "/api/v1/topics" => 200, "/api/v1/topics/#{topic.id}" => 200, "/api/v1/mailing_lists" => 200,
        "/api/v1/topics?nope=1" => 400, "/api/v1/topics?cursor=x" => 400, "/api/v1/me" => 401,
        "/api/v1/topics/0" => 404, "/api/v1/nothing/here" => 404, "/api/v1/openapi.json" => 200
      }
      requests.each do |path, status|
        [ {}, headers ].each do |caller|
          next if path == "/api/v1/me" && caller.any?

          get path, headers: caller
          expect(response.status).to eq(status), path
          expect(vary).to include("Authorization"), path
        end
      end

      get "/api/v1/topics", headers: { "Authorization" => "Bearer hko_nope" }
      expect(response).to have_http_status(:unauthorized)
      expect(vary).to include("Authorization")

      merged = create(:topic, creator_alias: sender, merged_into_topic_id: topic.id)
      get "/api/v1/topics/#{merged.id}", headers: headers
      expect(response).to have_http_status(:moved_permanently)
      expect(vary).to include("Authorization")
    end

    it "sends it on a throttled answer" do
      Rails.configuration.x.api_rate_limit.anonymous = 1
      get "/api/v1/topics"

      get "/api/v1/topics"

      expect(response).to have_http_status(:too_many_requests)
      expect(vary).to include("Authorization")
    end

    it "does not send it outside the API" do
      get "/up"

      expect(vary).not_to include("Authorization")
    end

    it "never marks an answer that depends on the token as public" do
      topic = thread

      [ "/api/v1/topics", "/api/v1/topics/#{topic.id}", "/api/v1/people/alice@example.org/topics",
        "/api/v1/me" ].each do |path|
        get path, headers: headers

        expect(response).to have_http_status(:ok), path
        expect(response.headers["Cache-Control"].to_s).not_to include("public"), path
      end
    end
  end
end
