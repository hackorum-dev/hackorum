require "rails_helper"

RSpec.describe "API v1 saved searches", type: :request do
  let(:user) { create(:user, username: "alice") }
  let(:other) { create(:user, username: "bob") }
  let(:team) { create(:team, name: "reviewers") }
  let(:creator) { create(:alias, :with_sent_messages, name: "Alice A", email: "alice@example.org") }
  let(:entry_keys) { %w[id name query scope team default topics_url] }

  before { create(:team_member, team: team, user: user) }

  def bearer(owner)
    { "Authorization" => "Bearer #{ApiToken.issue!(user: owner, name: 'laptop').last}" }
  end

  def body
    JSON.parse(response.body)
  end

  def data
    body["data"]
  end

  def error_code
    body.dig("error", "code")
  end

  def search(scope, name, **attrs)
    create(:saved_search, scope: scope, name: name, **attrs)
  end

  def list_as(owner)
    get "/api/v1/me/saved_searches", headers: bearer(owner)
    expect(response).to have_http_status(:ok)
    data
  end

  def topic(title, at)
    create(:topic, creator_alias: creator, title: title, last_message_at: at)
  end

  describe "GET /me/saved_searches" do
    it "needs a token" do
      get "/api/v1/me/saved_searches"

      expect(response).to have_http_status(:unauthorized)
      expect(error_code).to eq("token_required")
      expect(response.headers["WWW-Authenticate"]).to eq("Bearer")
    end

    it "gives the documented entries in the order of the sidebar" do
      second_team = create(:team, name: "hackers")
      create(:team_member, team: second_team, user: user)
      late = search("global", "Zebra", query: "title:zebra", position: 1)
      early = search("global", "Apples", query: "title:apples", position: 1)
      first = search("global", "Pinned", query: "title:pinned", position: 0)
      own = search("user", "Mine", query: "starred:me", user: user)
      template = search("user", "Unread", query: "unread:me")
      team_own = search("team", "Team queue", query: "notes:reviewers", team: team)
      team_template = search("team", "Team unread", query: "unread:{{team_name}} from:{{team_name}}")

      rows = list_as(user)

      expect(body.keys).to match_array(%w[data next_cursor])
      expect(body["next_cursor"]).to be_nil
      expect(rows.map(&:keys)).to all(match_array(entry_keys))
      expect(rows.map { |row| [ row["id"], row["team"]&.fetch("id") ] }).to eq([
        [ first.id, nil ], [ early.id, nil ], [ late.id, nil ],
        [ template.id, nil ], [ own.id, nil ],
        [ team_own.id, team.id ], [ team_template.id, team.id ],
        [ team_template.id, second_team.id ]
      ])
      expect(rows.first).to eq(
        "id" => first.id, "name" => "Pinned", "query" => "title:pinned", "scope" => "global", "team" => nil,
        "default" => false, "topics_url" => "http://www.example.com/api/v1/topics?saved_search_id=#{first.id}"
      )
      expect(rows[3]).to include("scope" => "user", "query" => "unread:me", "team" => nil)
      expect(rows[4]).to include("scope" => "user", "name" => "Mine")
      expect(rows[6]).to eq(
        "id" => team_template.id, "name" => "Team unread", "query" => "unread:reviewers from:reviewers",
        "scope" => "team", "team" => { "id" => team.id, "name" => "reviewers" }, "default" => false,
        "topics_url" => "http://www.example.com/api/v1/topics?saved_search_id=#{team_template.id}&team_id=#{team.id}"
      )
      expect(rows[7]).to include("query" => "unread:hackers from:hackers",
                                 "team" => { "id" => second_team.id, "name" => "hackers" })
    end

    it "leaves out what the user hid and what belongs to others" do
      shown = search("global", "Shown")
      hidden = search("global", "Hidden")
      hidden_template = search("team", "Hidden template", query: "from:{{team_name}}")
      create(:saved_search_preference, user: user, saved_search: hidden, hidden: true)
      create(:saved_search_preference, user: user, saved_search: hidden_template, hidden: true)
      create(:saved_search_preference, user: other, saved_search: shown, hidden: true)
      search("user", "Bob's", query: "starred:me", user: other)
      foreign_team = create(:team, name: "strangers")
      create(:team_member, team: foreign_team, user: other)
      search("team", "Strangers' queue", team: foreign_team)

      expect(list_as(user).map { |row| row["name"] }).to eq([ "Shown" ])
      expect(response.body).not_to include("Bob's", "strangers", "Strangers")

      expect(list_as(other).map { |row| [ row["name"], row["team"]&.fetch("name") ] })
        .to eq([ [ "Hidden", nil ], [ "Bob's", nil ], [ "Strangers' queue", "strangers" ], [ "Hidden template", "strangers" ] ])
    end

    it "marks the user's default" do
      plain = search("global", "Plain")
      chosen = search("global", "Chosen")
      create(:saved_search_preference, user: user, saved_search: chosen, default: true)
      create(:saved_search_preference, user: other, saved_search: plain, default: true)

      expect(list_as(user).to_h { |row| [ row["id"], row["default"] ] }).to eq(plain.id => false, chosen.id => true)
      expect(list_as(other).to_h { |row| [ row["id"], row["default"] ] }).to eq(plain.id => true, chosen.id => false)
    end

    it "gives a user without teams the global and the user searches only" do
      search("global", "Open")
      search("team", "Template", query: "from:{{team_name}}")

      expect(list_as(other).map { |row| row["name"] }).to eq([ "Open" ])
    end

    it "takes no parameters" do
      get "/api/v1/me/saved_searches", params: { limit: 1 }, headers: bearer(user)

      expect(response).to have_http_status(:bad_request)
      expect(error_code).to eq("invalid_parameter")
    end

    it "runs the same queries for one team and search and for three" do
      headers = bearer(user)
      get "/api/v1/me", headers: headers
      search("team", "Template 0", query: "from:{{team_name}}")
      search("global", "Global 0")
      one = captured_queries { get "/api/v1/me/saved_searches", headers: headers }
      expect(data.size).to eq(2)

      2.times do |i|
        extra = create(:team)
        create(:team_member, team: extra, user: user)
        search("team", "Queue #{i}", team: extra)
        search("team", "Template #{i + 1}", query: "from:{{team_name}}")
        hidden = search("global", "Hidden #{i}")
        create(:saved_search_preference, user: user, saved_search: hidden, hidden: true)
        search("user", "Own #{i}", user: user)
      end
      create(:saved_search_preference, user: user, saved_search: SavedSearch.find_by!(name: "Own 0"), default: true)
      three = captured_queries { get "/api/v1/me/saved_searches", headers: headers }

      expect(data.size).to eq(1 + 2 + 2 + 9)
      expect(three.size).to eq(one.size)
    end

    it "writes nothing and is not publicly cacheable" do
      search("global", "Open")
      headers = bearer(user)

      queries = captured_queries { get "/api/v1/me/saved_searches", headers: headers }

      expect(response).to have_http_status(:ok)
      expect(queries.grep(/\A\s*(INSERT|UPDATE|DELETE)/i).grep_v(/api_tokens/)).to be_empty
      expect(response.headers["Vary"].to_s).to include("Authorization")
      expect(response.headers["Cache-Control"].to_s).not_to include("public")
    end
  end

  describe "GET /topics with saved_search_id" do
    let(:start) { Time.zone.parse("2026-03-01 10:00:00") }
    let!(:apples) { topic("Apples fruit", start) }
    let!(:pears) { topic("Pears fruit", start + 1.hour) }

    def topics_as(owner = nil, **params)
      get "/api/v1/topics", params: params, headers: owner ? bearer(owner) : {}
    end

    def titles
      data.map { |row| row["title"] }
    end

    it "runs a global search with and without a token and says what ran" do
      saved = search("global", "Apples", query: "title:apples")

      [ nil, user ].each do |caller|
        topics_as(caller, saved_search_id: saved.id)

        expect(response).to have_http_status(:ok)
        expect(body.keys).to match_array(%w[data next_cursor warnings query])
        expect(body["query"]).to eq("title:apples")
        expect(titles).to eq([ "Apples fruit" ])
      end
    end

    it "does not add query to a list without a saved search" do
      topics_as
      expect(body.keys).to match_array(%w[data next_cursor warnings])

      topics_as(user, q: "title:apples")
      expect(body.keys).to match_array(%w[data next_cursor warnings])
    end

    it "runs the user's own search and a user template as the user" do
      create(:topic_star, user: user, topic: pears)
      own = search("user", "Mine", query: "title:pears", user: user)
      template = search("user", "Starred", query: "starred:me")

      topics_as(user, saved_search_id: own.id)
      expect(titles).to eq([ "Pears fruit" ])

      topics_as(user, saved_search_id: template.id)
      expect(titles).to eq([ "Pears fruit" ])
      expect(body["warnings"]).to eq([])

      topics_as(other, saved_search_id: template.id)
      expect(titles).to eq([])
    end

    it "hides the searches the caller may not see behind a 404" do
      own = search("user", "Mine", query: "title:pears", user: user)
      template = search("user", "Starred", query: "starred:me")
      team_own = search("team", "Queue", query: "title:apples", team: team)
      team_template = search("team", "Template", query: "title:{{team_name}}")

      [ own, template, team_own, team_template ].each do |saved|
        topics_as(saved_search_id: saved.id)
        expect(response).to have_http_status(:not_found), saved.name
        expect(error_code).to eq("not_found")
      end
      [ own, team_own ].each do |saved|
        topics_as(other, saved_search_id: saved.id)
        expect(response).to have_http_status(:not_found), saved.name
      end

      topics_as(user, saved_search_id: 999_999_999)
      expect(response).to have_http_status(:not_found)
      topics_as(user, saved_search_id: "99999999999999999999999999")
      expect(response).to have_http_status(:not_found)
    end

    it "runs a team search and fills the team name into a template" do
      topic("reviewers wanted", start + 2.hours)
      team_own = search("team", "Queue", query: "title:apples", team: team)
      team_template = search("team", "Template", query: "title:{{team_name}}")

      topics_as(user, saved_search_id: team_own.id, team_id: team.id)
      expect(titles).to eq([ "Apples fruit" ])
      topics_as(user, saved_search_id: team_own.id)
      expect(titles).to eq([ "Apples fruit" ])

      topics_as(user, saved_search_id: team_template.id, team_id: team.id)
      expect(response).to have_http_status(:ok)
      expect(body["query"]).to eq("title:reviewers")
      expect(titles).to eq([ "reviewers wanted" ])
    end

    it "runs what the list of saved searches links to" do
      search("global", "Apples", query: "title:apples")
      search("team", "Template", query: "title:{{team_name}}")
      headers = bearer(user)
      get "/api/v1/me/saved_searches", headers: headers
      entries = data

      entries.each do |entry|
        get entry["topics_url"], headers: headers
        expect(response).to have_http_status(:ok), entry["name"]
        expect(body["query"]).to eq(entry["query"])
      end
      expect(entries.size).to eq(2)
    end

    it "answers a team the caller cannot access with 404, as the site does" do
      closed = create(:team, name: "closed", visibility: "private")
      create(:team_member, team: closed, user: other)
      open = create(:team, name: "apples", visibility: "visible")
      team_template = search("team", "Template", query: "title:{{team_name}}")

      topics_as(user, saved_search_id: team_template.id, team_id: closed.id)
      expect(response).to have_http_status(:not_found)
      expect(error_code).to eq("not_found")

      topics_as(user, saved_search_id: team_template.id, team_id: 999_999_999)
      expect(response).to have_http_status(:not_found)

      topics_as(user, saved_search_id: team_template.id, team_id: open.id)
      expect(response).to have_http_status(:ok)
      expect(body["query"]).to eq("title:apples")
    end

    it "fills the name of the owning team into a team's own search" do
      topic("reviewers wanted", start + 2.hours)
      owned = search("team", "Ours", query: "title:{{team_name}}", team: team)
      open = create(:team, name: "apples", visibility: "visible")

      topics_as(user, saved_search_id: owned.id)
      expect(response).to have_http_status(:ok)
      expect(body["query"]).to eq("title:reviewers")
      expect(titles).to eq([ "reviewers wanted" ])

      topics_as(user, saved_search_id: owned.id, team_id: open.id)
      expect(body["query"]).to eq("title:apples")

      topics_as(other, saved_search_id: owned.id)
      expect(response).to have_http_status(:not_found)
    end

    it "asks for team_id when a team search still has the placeholder" do
      team_template = search("team", "Template", query: "title:{{team_name}}")

      topics_as(user, saved_search_id: team_template.id)

      expect(response).to have_http_status(:bad_request)
      expect(error_code).to eq("invalid_parameter")
      expect(body.dig("error", "message")).to include("team_id")
    end

    it "ignores team_id on a search that is not a team search, as the site does" do
      saved = search("global", "Apples", query: "title:apples")

      topics_as(user, saved_search_id: saved.id, team_id: 999_999_999)

      expect(response).to have_http_status(:ok)
      expect(titles).to eq([ "Apples fruit" ])
    end

    it "rejects q with it, team_id without it and malformed ids" do
      saved = search("global", "Apples", query: "title:apples")

      topics_as(saved_search_id: saved.id, q: "pears")
      expect(response).to have_http_status(:bad_request)
      expect(error_code).to eq("invalid_parameter")

      topics_as(user, team_id: team.id)
      expect(response).to have_http_status(:bad_request)
      expect(error_code).to eq("invalid_parameter")

      [ { saved_search_id: "abc" }, { saved_search_id: "-1" }, { saved_search_id: saved.id, team_id: "x" } ].each do |params|
        topics_as(user, **params)
        expect(response).to have_http_status(:bad_request), params.to_s
        expect(error_code).to eq("invalid_parameter"), params.to_s
      end

      get "/api/v1/topics?saved_search_id[]=#{saved.id}"
      expect(error_code).to eq("invalid_parameter")
    end

    it "combines with list, author and sort" do
      list = create(:mailing_list, identifier: "pgsql-hackers", display_name: "pgsql-hackers")
      create(:topic_mailing_list, topic: apples, mailing_list: list)
      saved = search("global", "All", query: "title:fruit")

      topics_as(saved_search_id: saved.id)
      expect(titles).to eq([ "Pears fruit", "Apples fruit" ])

      topics_as(saved_search_id: saved.id, list: "pgsql-hackers")
      expect(titles).to eq([ "Apples fruit" ])

      topics_as(saved_search_id: saved.id, author: "nobody@example.org")
      expect(titles).to eq([])

      topics_as(saved_search_id: saved.id, sort: "created")
      expect(response).to have_http_status(:ok)
      expect(titles.size).to eq(2)
    end

    it "sends the stored query through the checks of q" do
      broken = search("global", "Broken", query: "title:(")
      long = search("global", "Long", query: "a " * 300)
      warned = search("global", "Warned", query: "starred:me")

      [ broken, long ].each do |saved|
        topics_as(saved_search_id: saved.id)
        expect(response).to have_http_status(:bad_request), saved.name
        expect(error_code).to eq("invalid_query"), saved.name
      end

      topics_as(saved_search_id: warned.id)
      expect(response).to have_http_status(:ok)
      expect(body["warnings"]).not_to be_empty
    end

    it "pages with a cursor that belongs to the saved search and the team" do
      saved = search("global", "All", query: "title:fruit")
      second = search("global", "Also all", query: "title:fruit OR title:pears")
      team_template = search("team", "Template", query: "title:fruit -title:{{team_name}}")
      open = create(:team, name: "hackers", visibility: "visible")
      headers = bearer(user)

      get "/api/v1/topics", params: { saved_search_id: saved.id, limit: 1 }, headers: headers
      cursor = body["next_cursor"]
      expect(cursor).to be_present
      get "/api/v1/topics", params: { saved_search_id: saved.id, limit: 1, cursor: cursor }, headers: headers
      expect(titles).to eq([ "Apples fruit" ])
      expect(body["query"]).to eq("title:fruit")

      get "/api/v1/topics", params: { saved_search_id: second.id, cursor: cursor }, headers: headers
      expect(error_code).to eq("invalid_cursor")
      get "/api/v1/topics", params: { q: "title:fruit", cursor: cursor }, headers: headers
      expect(error_code).to eq("invalid_cursor")

      get "/api/v1/topics", params: { saved_search_id: team_template.id, team_id: team.id, limit: 1 }, headers: headers
      team_cursor = body["next_cursor"]
      expect(team_cursor).to be_present
      get "/api/v1/topics", params: { saved_search_id: team_template.id, team_id: open.id, cursor: team_cursor },
                            headers: headers
      expect(error_code).to eq("invalid_cursor")
    end
  end
end
