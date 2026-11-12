require "rails_helper"

RSpec.describe "API v1 /topics", type: :request do
  let(:creator) { create(:alias, :with_sent_messages, name: "Alice A", email: "alice@example.org") }
  let(:replier) { create(:alias, :with_sent_messages, name: "Bob B", email: "bob@example.org") }
  let(:hackers) { create(:mailing_list, identifier: "pgsql-hackers", display_name: "pgsql-hackers") }

  let(:brief_keys) do
    %w[id slug title url html_url created_at last_message_at message_count participant_count
       contributor_participant_count highest_contributor_type has_attachments commit_count last_commit_at
       creator last_sender mailing_lists commitfest ci me]
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

  def topic_at(time, **attrs)
    create(:topic, creator_alias: creator, last_message_at: time, **attrs)
  end

  def join(topic, person_alias, count: 1)
    TopicParticipant.create!(topic: topic, person: person_alias.person, message_count: count,
                             first_message_at: 2.days.ago, last_message_at: 1.day.ago)
  end

  def decorate(topic)
    create(:topic_mailing_list, topic: topic, mailing_list: hackers)
    patch = create(:commitfest_patch, external_id: 4000 + topic.id, reviewers: "Carol, Dave", committer: "Eve")
    create(:commitfest_patch_topic, commitfest_patch: patch, topic: topic)
    commitfest = create(:commitfest, external_id: 5000 + topic.id, name: "PG19-1")
    create(:commitfest_patch_commitfest, commitfest_patch: patch, commitfest: commitfest, status: "Needs review",
                                         ci_status: "passing")
    branch = create(:patch_branch, topic: topic, message: message_without_callbacks(topic),
                                   branch_name: "t#{topic.id}_1", pushed_at: 1.hour.ago, base_committed_at: 1.day.ago)
    run = create(:patch_ci_run, patch_branch: branch, status: "success")
    branch.update_columns(latest_ci_run_id: run.id, ci_status: "success")
    branch
  end

  # a message whose creation leaves the topic's counters alone
  def message_without_callbacks(topic, sender: creator, **attrs)
    kept = topic.reload.attributes.slice("last_message_at", "last_message_id", "last_sender_person_id",
                                         "message_count", "participant_count", "contributor_participant_count")
    participants = topic.topic_participants.pluck(:id)
    message = create(:message, topic: topic, sender: sender, **attrs)
    topic.topic_participants.where.not(id: participants).delete_all
    topic.update_columns(kept)
    message
  end

  describe "GET /topics" do
    it "lists topics with the documented row without a token" do
      create(:patch_ci_repo_state)
      topic = topic_at(Time.zone.parse("2026-03-04 05:06:07"), title: "Add a feature", slug: "add-feature",
                       created_at: Time.zone.parse("2026-03-01 00:00:00"), message_count: 4, participant_count: 2,
                       contributor_participant_count: 1, highest_contributor_type: "committer",
                       has_attachments: true, last_sender_person_id: replier.person_id)
      branch = decorate(topic)

      get "/api/v1/topics"

      expect(response).to have_http_status(:ok)
      expect(response.headers["RateLimit-Limit"]).to be_present
      expect(body.keys).to match_array(%w[data next_cursor warnings])
      expect(body).to include("next_cursor" => nil, "warnings" => [])
      row = data.first
      expect(row.keys).to match_array(brief_keys)
      expect(row).to include(
        "id" => topic.id, "slug" => "add-feature", "title" => "Add a feature",
        "created_at" => "2026-03-01T00:00:00.000Z", "last_message_at" => "2026-03-04T05:06:07.000Z",
        "message_count" => 4, "participant_count" => 2, "contributor_participant_count" => 1,
        "highest_contributor_type" => "committer", "has_attachments" => true,
        "commit_count" => 0, "last_commit_at" => nil
      )
      expect(row["url"]).to end_with("/api/v1/topics/#{topic.id}")
      expect(row["html_url"]).to end_with("/topics/#{topic.id}")
      expect(row["html_url"]).not_to include("/api/")
      expect(row["creator"]).to include("id" => creator.person_id, "name" => "Alice A", "email" => "alice@example.org")
      expect(row["last_sender"]).to include("id" => replier.person_id, "name" => "Bob B")
      expect(row["mailing_lists"]).to eq([ { "identifier" => "pgsql-hackers", "display_name" => "pgsql-hackers" } ])
      expect(row["commitfest"]).to eq(
        "name" => "PG19-1", "status" => "Needs review", "committed" => false,
        "commitfest_url" => "https://commitfest.postgresql.org/#{5000 + topic.id}/",
        "patch_url" => "https://commitfest.postgresql.org/patch/#{4000 + topic.id}/"
      )
      expect(row["ci"].except("url")).to eq("state" => "applies", "ci_status" => "success",
                                            "branch_id" => branch.id, "branch_name" => "t#{topic.id}_1")
      expect(row["ci"]["url"]).to end_with("/api/v1/branches/#{branch.id}")
    end

    it "gives nulls and empty lists for a bare topic" do
      topic_at(1.day.ago)

      get "/api/v1/topics"

      expect(data.first).to include("slug" => nil, "last_sender" => nil, "mailing_lists" => [],
                                    "commitfest" => nil, "ci" => nil, "highest_contributor_type" => nil)
    end

    it "leaves out hidden-list and merged topics, and topics without messages" do
      shown = topic_at(3.days.ago)
      topic_at(2.days.ago, hidden_by_default: true)
      topic_at(1.day.ago, merged_into_topic_id: shown.id)
      topic_at(nil)

      get "/api/v1/topics"

      expect(ids).to eq([ shown.id ])
    end

    it "finds hidden-list topics with q, as the site search does" do
      shown = topic_at(3.days.ago, title: "vacuum one")
      hidden = topic_at(2.days.ago, title: "vacuum two", hidden_by_default: true)
      topic_at(1.day.ago, title: "vacuum three", merged_into_topic_id: shown.id)

      get "/api/v1/topics", params: { q: "title:vacuum" }
      expect(ids).to eq([ hidden.id, shown.id ])

      get "/api/v1/topics", params: { q: "title:vacuum hidden:false" }
      expect(ids).to eq([ shown.id ])
    end

    it "pages by activity through ties" do
      at = Time.zone.parse("2026-02-02 02:02:02")
      tied = Array.new(3) { topic_at(at) }
      older = topic_at(at - 1.hour)

      get "/api/v1/topics", params: { limit: 2 }
      expect(ids).to eq([ tied[2].id, tied[1].id ])
      cursor = body["next_cursor"]
      expect(cursor).to be_present

      get "/api/v1/topics", params: { limit: 2, cursor: cursor }
      expect(ids).to eq([ tied[0].id, older.id ])
      expect(body["next_cursor"]).to be_nil
    end

    it "pages by creation through ties" do
      at = Time.zone.parse("2026-02-02 02:02:02")
      tied = Array.new(3) { |i| topic_at(i.days.ago, created_at: at) }
      older = topic_at(nil, created_at: at - 1.hour)

      get "/api/v1/topics", params: { sort: "created", limit: 3 }
      expect(ids).to eq(tied.reverse.map(&:id))

      get "/api/v1/topics", params: { sort: "created", limit: 3, cursor: body["next_cursor"] }
      expect(ids).to eq([ older.id ])
      expect(body["next_cursor"]).to be_nil
    end

    it "rejects an unknown sort and non-string parameters" do
      get "/api/v1/topics", params: { sort: "title" }
      expect(response).to have_http_status(:bad_request)
      expect(error_code).to eq("invalid_parameter")

      get "/api/v1/topics?q[]=a"
      expect(response).to have_http_status(:bad_request)
      expect(error_code).to eq("invalid_parameter")
    end

    it "rejects a parameter it does not know, naming it" do
      topic_at(1.day.ago)

      get "/api/v1/topics", params: { autor: "alice@example.org" }
      expect(response).to have_http_status(:bad_request)
      expect(error_code).to eq("invalid_parameter")
      expect(body.dig("error", "message")).to eq("unknown parameter: autor")

      get "/api/v1/topics?limit=1&#{'x' * 300}=1"
      expect(error_code).to eq("invalid_parameter")
      expect(body.dig("error", "message")).to eq("unknown parameter: #{'x' * 100}")

      %w[format=json controller=x action=show id=1].each do |query|
        get "/api/v1/topics?#{query}"
        expect(response).to have_http_status(:bad_request), query
        expect(error_code).to eq("invalid_parameter")
      end
    end

    it "rejects a blank value of every parameter" do
      topic_at(1.day.ago)

      %w[q list author sort limit cursor].each do |name|
        [ "", "%20", "%09%20" ].each do |value|
          get "/api/v1/topics?#{name}=#{value}"
          expect(response).to have_http_status(:bad_request), "#{name}=#{value}"
          expect(error_code).to eq("invalid_parameter")
          expect(body.dig("error", "message")).to eq("#{name} must not be blank")
        end
      end
    end

    it "keeps the specific codes for values that are not blank" do
      get "/api/v1/topics", params: { limit: "x" }
      expect(error_code).to eq("invalid_limit")

      get "/api/v1/topics", params: { cursor: "x" }
      expect(error_code).to eq("invalid_cursor")

      get "/api/v1/topics", params: { cursor: "x" * 501 }
      expect(error_code).to eq("invalid_cursor")

      get "/api/v1/topics", params: { q: "(" }
      expect(error_code).to eq("invalid_query")

      get "/api/v1/topics", params: { list: "x" * 101 }
      expect(error_code).to eq("invalid_parameter")
      expect(body.dig("error", "message")).to include("too long")
    end

    it "takes a cursor only with the filters it came from" do
      bugs = create(:mailing_list, identifier: "pgsql-bugs", display_name: "pgsql-bugs")
      3.times do |i|
        topic = topic_at((i + 1).days.ago)
        [ hackers, bugs ].each { |list| create(:topic_mailing_list, topic: topic, mailing_list: list) }
        join(topic, replier)
      end
      get "/api/v1/topics", params: { list: "pgsql-hackers", limit: 1 }
      cursor = body["next_cursor"]
      first = ids

      [ { list: "pgsql-bugs" }, {}, { list: "pgsql-hackers", author: "bob@example.org" },
        { list: "pgsql-hackers", q: "title:x" }, { list: "pgsql-hackers", sort: "activity" } ].each do |params|
        get "/api/v1/topics", params: params.merge(cursor: cursor)
        expect(response).to have_http_status(:bad_request), params.inspect
        expect(error_code).to eq("invalid_cursor")
      end

      get "/api/v1/topics?cursor=#{cursor}&limit=2&list=pgsql-hackers"
      expect(response).to have_http_status(:ok)
      expect(ids.size).to eq(2)
      expect(ids & first).to eq([])
    end

    it "rejects a cursor of the other sort" do
      2.times { topic_at(1.day.ago) }
      get "/api/v1/topics", params: { sort: "created", limit: 1 }
      cursor = body["next_cursor"]
      expect(cursor).to be_present

      get "/api/v1/topics", params: { limit: 1, cursor: cursor }
      expect(response).to have_http_status(:bad_request)
      expect(error_code).to eq("invalid_cursor")

      get "/api/v1/topics", params: { sort: "created", limit: 1, cursor: cursor }
      expect(response).to have_http_status(:ok)
      expect(data.size).to eq(1)
    end

    it "filters by q, list, author and all of them" do
      bugs = create(:mailing_list, identifier: "pgsql-bugs", display_name: "pgsql-bugs")
      a = topic_at(4.days.ago, title: "foo on hackers by bob")
      b = topic_at(3.days.ago, title: "foo on bugs by bob")
      c = topic_at(2.days.ago, title: "foo on hackers")
      d = topic_at(1.day.ago, title: "bar on hackers by bob")
      [ a, c, d ].each { |topic| create(:topic_mailing_list, topic: topic, mailing_list: hackers) }
      create(:topic_mailing_list, topic: b, mailing_list: bugs)
      [ a, b, d ].each { |topic| join(topic, replier) }

      get "/api/v1/topics", params: { q: "title:foo" }
      expect(ids).to eq([ c.id, b.id, a.id ])

      get "/api/v1/topics", params: { list: "pgsql-hackers" }
      expect(ids).to eq([ d.id, c.id, a.id ])

      get "/api/v1/topics", params: { author: "Bob@example.org" }
      expect(ids).to eq([ d.id, b.id, a.id ])

      get "/api/v1/topics", params: { q: "title:foo", list: "pgsql-hackers", author: "bob@example.org" }
      expect(ids).to eq([ a.id ])
      expect(body["warnings"]).to eq([])
    end

    it "rejects an unknown list and answers an unknown author with nothing" do
      topic_at(1.day.ago)

      get "/api/v1/topics", params: { list: "nope" }
      expect(response).to have_http_status(:bad_request)
      expect(error_code).to eq("invalid_parameter")

      get "/api/v1/topics", params: { author: "nobody@example.org" }
      expect(response).to have_http_status(:ok)
      expect(body).to eq("data" => [], "next_cursor" => nil, "warnings" => [])
    end

    it "rejects a blank or over-long author" do
      topic_at(1.day.ago)

      [ "", " ", "#{'a' * 243}@example.org" ].each do |author|
        get "/api/v1/topics", params: { author: author }
        expect(response).to have_http_status(:bad_request), author.first(20).inspect
        expect(error_code).to eq("invalid_parameter")
        expect(body.dig("error", "message")).to include("author")
      end

      get "/api/v1/topics", params: { author: "#{'a' * 242}@example.org" }
      expect(response).to have_http_status(:ok)
    end

    it "answers a broken query with invalid_query, never a 500" do
      topic_at(1.day.ago, title: "foo")
      queries = [ 'title:"open', "(foo OR", "foo)", "[foo", "a" * 3000, "#{'(' * 40}a#{')' * 40}",
                  "title:", "::::", "-", "\"", "OR OR OR" ]

      queries.each do |q|
        get "/api/v1/topics", params: { q: q }
        expect(response.status).to be_in([ 200, 400 ]), "#{q.first(20).inspect} gave #{response.status}"
        expect(error_code).to eq("invalid_query") if response.status == 400
      end

      get "/api/v1/topics", params: { q: 'title:"open' }
      expect(response).to have_http_status(:bad_request)
      expect(error_code).to eq("invalid_query")
      expect(body.dig("error", "message")).to be_present

      get "/api/v1/topics", params: { q: "a" * 3000 }
      expect(response).to have_http_status(:bad_request)
      expect(body.dig("error", "message")).to eq("query too long, at most 500 characters")
    end

    it "takes a query of at most 500 characters" do
      topic_at(1.day.ago, title: "foo")
      longest = "#{'foo ' * 124}fooo"
      expect(longest.length).to eq(500)

      get "/api/v1/topics", params: { q: longest }
      expect(response).to have_http_status(:ok)

      [ "#{longest}o", "#{' ' * 499}ab", "a" * 501 ].each do |q|
        get "/api/v1/topics", params: { q: q }

        expect(response).to have_http_status(:bad_request)
        expect(error_code).to eq("invalid_query")
        expect(body.dig("error", "message")).to eq("query too long, at most 500 characters")
      end
    end

    it "rejects a NUL byte in any string parameter" do
      topic_at(1.day.ago)

      %w[q list author sort].each do |name|
        get "/api/v1/topics?#{name}=a%00b"

        expect(response).to have_http_status(:bad_request), "#{name} gave #{response.status}"
        expect(error_code).to eq("invalid_parameter")
        expect(body.dig("error", "message")).to include(name)
      end
    end

    it "lists a hidden list when asked for it" do
      hidden_list = create(:mailing_list, identifier: "pgsql-hidden", hidden_by_default: true)
      shown = topic_at(3.days.ago)
      hidden = topic_at(2.days.ago, hidden_by_default: true)
      merged = topic_at(1.day.ago, hidden_by_default: true, merged_into_topic_id: hidden.id)
      create(:topic_mailing_list, topic: shown, mailing_list: hackers)
      [ hidden, merged ].each { |topic| create(:topic_mailing_list, topic: topic, mailing_list: hidden_list) }

      get "/api/v1/topics", params: { list: "pgsql-hidden" }
      expect(response).to have_http_status(:ok)
      expect(ids).to eq([ hidden.id ])

      get "/api/v1/topics"
      expect(ids).to eq([ shown.id ])
    end

    it "survives odd selector values" do
      topic_at(1.day.ago, title: "foo")

      [ "first_after:9999-99-99", "title:%_%", "foo:bar:baz", "tag:",
        "from:a@b from:c@d -from:e", "NOT NOT a", "a OR (b AND -c)", "'; DROP TABLE topics; --", "\u00e9\u{1F600}", "from:%_\\", "foo & | ! bar", "list:\\",
        "last_before:0001-01-01", "participants:<-1", "has:attachment:>999999999999" ].each do |q|
        get "/api/v1/topics", params: { q: q }
        expect(response.status).to be_in([ 200, 400 ]), "#{q.inspect} gave #{response.status}"
      end
    end

    it "answers a value the database cannot take with invalid_query" do
      get "/api/v1/topics", params: { q: "messages:>99999999999999999999" }

      expect(response).to have_http_status(:bad_request)
      expect(error_code).to eq("invalid_query")
    end

    it "warns about a bad selector value and still answers" do
      topic = topic_at(1.day.ago, title: "foo")

      get "/api/v1/topics", params: { q: "title:foo has:nonsense" }

      expect(response).to have_http_status(:ok)
      expect(ids).to eq([ topic.id ])
      expect(body["warnings"]).to include(a_string_matching(/has:/))
    end

    context "with a token" do
      let(:user) { create(:user, username: "alice") }
      let(:headers) { { "Authorization" => "Bearer #{ApiToken.issue!(user: user, name: 'laptop').last}" } }

      it "answers as the token's user: ignore filter and user selectors" do
        topic = topic_at(1.day.ago, title: "foo")
        create(:topic_ignore, user: user, topic: topic)

        get "/api/v1/topics", headers: headers
        expect(ids).to eq([])

        get "/api/v1/topics", params: { q: "title:foo" }, headers: headers
        expect(ids).to eq([])

        get "/api/v1/topics", params: { q: "title:foo ignored:me" }, headers: headers
        expect(ids).to eq([ topic.id ])
        expect(body["warnings"]).to eq([])

        get "/api/v1/topics", params: { q: "from:me" }, headers: headers
        expect(response).to have_http_status(:ok)
        expect(data).to eq([])
        expect(body["warnings"]).to eq([])
      end

      it "writes nothing" do
        topic = topic_at(1.day.ago, slug: "quiet")
        message_without_callbacks(topic)
        user

        queries = captured_queries do
          get "/api/v1/topics", headers: headers
          get "/api/v1/topics", params: { q: "quiet" }, headers: headers
          get "/api/v1/topics/#{topic.id}", headers: headers
          get "/api/v1/topics/quiet", headers: headers
        end

        expect(response).to have_http_status(:ok)
        expect(ThreadAwareness.count).to eq(0)
        expect(MessageReadRange.count).to eq(0)
        writes = queries.grep(/\A\s*(INSERT|UPDATE|DELETE)/i)
        expect(writes.grep_v(/api_tokens/)).to be_empty
      end
    end

    it "runs the same queries when people have no default alias" do
      bare = lambda do |time|
        starter = create(:alias, :with_sent_messages)
        sender = create(:alias, :with_sent_messages)
        topic = create(:topic, creator_alias: starter, last_message_at: time, last_sender_person_id: sender.person_id)
        Person.where(id: [ starter.person_id, sender.person_id ]).update_all(default_alias_id: nil)
        [ topic, starter, sender ]
      end

      _, starter, sender = bare.call(1.day.ago)
      one = captured_queries { get "/api/v1/topics" }
      expect(data.first["creator"]).to include("name" => starter.name, "email" => starter.email)
      expect(data.first["creator"]["url"]).to end_with("/people/#{ERB::Util.url_encode(starter.email)}")
      expect(data.first["last_sender"]).to include("name" => sender.name, "email" => sender.email)

      2.times { |i| bare.call((i + 2).days.ago) }
      three = captured_queries { get "/api/v1/topics" }

      expect(data.size).to eq(3)
      expect(data.map { |row| row["creator"]["email"] }).to all(be_present)
      expect(three.size).to eq(one.size)
    end

    it "runs the same queries for one row and for three" do
      create(:patch_ci_repo_state)
      first = topic_at(1.day.ago, last_sender_person_id: replier.person_id)
      decorate(first)
      one = captured_queries { get "/api/v1/topics" }
      expect(data.size).to eq(1)

      2.times do |i|
        other = create(:alias, :with_sent_messages)
        topic = create(:topic, creator_alias: other, last_message_at: (i + 2).days.ago,
                               last_sender_person_id: create(:alias).person_id)
        decorate(topic)
      end
      three = captured_queries { get "/api/v1/topics" }

      expect(data.size).to eq(3)
      expect(data.map { |row| row["commitfest"] && row["mailing_lists"].any? }).to all(be_truthy)
      expect(data.map { |row| row["ci"].slice("state", "ci_status") })
        .to all(eq("state" => "applies", "ci_status" => "success"))
      expect(PatchBranch.where.not(latest_ci_run_id: nil).count).to eq(3)
      expect(three.size).to eq(one.size)
    end

    describe "ci" do
      let(:topic) { topic_at(1.day.ago) }
      let(:message) { message_without_callbacks(topic) }

      it "is null without a repo state" do
        create(:patch_branch, topic: topic, message: message, ci_status: "success")

        get "/api/v1/topics"

        expect(response).to have_http_status(:ok)
        expect(data.first["ci"]).to be_nil
      end

      it "is null for a patchset the site shows no icon for" do
        create(:patch_ci_repo_state)
        create(:patch_branch, topic: topic, message: message, pushed_at: 1.hour.ago, base_committed_at: 1.day.ago)
        topic.update_columns(last_commit_at: Time.current)

        get "/api/v1/topics"

        expect(response).to have_http_status(:ok)
        expect(data.first["ci"]).to be_nil
      end

      it "reports a patchset that does not apply" do
        create(:patch_ci_repo_state)
        branch = create(:patch_branch, topic: topic, message: message, status: "failed", on_master: false,
                                       failure_stage: "apply")

        get "/api/v1/topics"

        expect(data.first["ci"].except("url")).to eq("state" => "never_applied", "ci_status" => nil,
                                                     "branch_id" => branch.id, "branch_name" => branch.branch_name)
        expect(data.first["ci"]["url"]).to end_with("/api/v1/branches/#{branch.id}")
      end
    end
  end

  describe "GET /topics/{id}" do
    let(:topic) do
      topic_at(Time.zone.parse("2026-03-04 05:06:07"), title: "Add a feature", slug: "feature-1.0",
               message_count: 3, participant_count: 2)
    end

    it "gives the detail by id" do
      create(:patch_ci_repo_state)
      decorate(topic)
      message_without_callbacks(topic, sender: replier, is_patch_submission: true)
      message_without_callbacks(topic, is_patch_submission: true)
      join(topic, creator, count: 1)
      join(topic, replier, count: 2)
      ContributorMembership.create!(person: replier.person, contributor_type: "committer")

      get "/api/v1/topics/#{topic.id}"

      expect(response).to have_http_status(:ok)
      expect(body.keys).to match_array(brief_keys + %w[participants commitfest_patches patchset_count links])
      expect(body).to include("id" => topic.id, "slug" => "feature-1.0", "title" => "Add a feature",
                              "patchset_count" => 2)
      expect(body["mailing_lists"].size).to eq(1)
      expect(body["commitfest"]).to include("name" => "PG19-1")
      expect(body["ci"]).to include("state" => "applies")
      expect(body["participants"].map { |row| row["person"]["email"] }).to eq(%w[bob@example.org alice@example.org])
      expect(body["participants"].first).to include("message_count" => 2, "contributor_type" => "committer")
      expect(body["participants"].first.keys).to match_array(
        %w[person message_count first_message_at last_message_at contributor_type]
      )
      expect(body["participants"].last["contributor_type"]).to be_nil
      expect(body["commitfest_patches"]).to eq([ {
        "external_id" => 4000 + topic.id, "title" => CommitfestPatch.last.title, "status" => "Needs review",
        "commitfest_name" => "PG19-1", "reviewers" => %w[Carol Dave], "committer" => "Eve", "tags" => [],
        "ci_status" => "passing", "url" => "https://commitfest.postgresql.org/patch/#{4000 + topic.id}/"
      } ])
      expect(body["links"].keys).to match_array(%w[messages patchsets commits])
      expect(body["links"]["messages"]).to end_with("/api/v1/topics/#{topic.id}/messages")
      expect(body["links"]["patchsets"]).to end_with("/api/v1/topics/#{topic.id}/patchsets")
      expect(body["links"]["commits"]).to end_with("/api/v1/topics/#{topic.id}/commits")
    end

    it "gives the detail by slug, with a dot and in any case" do
      topic

      get "/api/v1/topics/feature-1.0"
      expect(response).to have_http_status(:ok)
      expect(body["id"]).to eq(topic.id)
      expect(body).to include("participants" => [], "commitfest_patches" => [], "patchset_count" => 0)

      get "/api/v1/topics/Feature-1.0"
      expect(response).to have_http_status(:ok)
      expect(body["id"]).to eq(topic.id)
    end

    it "shows a hidden-list topic" do
      hidden = topic_at(1.day.ago, hidden_by_default: true)

      get "/api/v1/topics/#{hidden.id}"

      expect(response).to have_http_status(:ok)
    end

    it "caps participants at 50" do
      52.times { |i| join(topic, create(:alias), count: i + 1) }

      get "/api/v1/topics/#{topic.id}"

      expect(body["participants"].size).to eq(50)
      expect(body["participants"].first["message_count"]).to eq(52)
    end

    it "answers a merged topic with a 301 to the final one" do
      middle = topic_at(2.days.ago, merged_into_topic_id: topic.id)
      source = topic_at(3.days.ago, merged_into_topic_id: middle.id, slug: "old-name")

      get "/api/v1/topics/#{source.id}"
      expect(response).to have_http_status(:moved_permanently)
      expect(response.body).to be_empty
      expect(response.headers["Location"]).to end_with("/api/v1/topics/#{topic.id}")
      expect(response.headers["RateLimit-Limit"]).to be_present

      get "/api/v1/topics/old-name"
      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers["Location"]).to end_with("/api/v1/topics/#{topic.id}")
    end

    it "keeps the query string on the redirect" do
      source = topic_at(3.days.ago, merged_into_topic_id: topic.id, slug: "old-name")

      get "/api/v1/topics/#{source.id}/messages?limit=5&body=none"
      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers["Location"]).to end_with("/api/v1/topics/#{topic.id}/messages?limit=5&body=none")

      get "/api/v1/topics/old-name?"
      expect(response.headers["Location"]).to end_with("/api/v1/topics/#{topic.id}")
    end

    it "builds the redirect from the configured host" do
      source = topic_at(3.days.ago, merged_into_topic_id: topic.id)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("APP_HOST").and_return("hackorum.example")

      get "/api/v1/topics/#{source.id}"

      expect(response.headers["Location"]).to eq("https://hackorum.example/api/v1/topics/#{topic.id}")
    end

    it "takes no query parameters" do
      topic = topic_at(1.day.ago)

      get "/api/v1/topics/#{topic.id}?body=none"
      expect(response).to have_http_status(:bad_request)
      expect(error_code).to eq("invalid_parameter")
      expect(body.dig("error", "message")).to eq("unknown parameter: body")

      get "/api/v1/topics/#{topic.id}?"
      expect(response).to have_http_status(:ok)
    end

    it "answers unknown ids and slugs with a JSON 404" do
      [ "0", "999999999", "9223372036854775808", "99999999999999999999999999", "no-such-slug", "a..b", "x%00y",
        "a%20b" ].each do |id|
        get "/api/v1/topics/#{id}"

        expect(response).to have_http_status(:not_found), "#{id} gave #{response.status}"
        expect(error_code).to eq("not_found")
      end
    end

    it "does not depend on the number of participants for its query count" do
      join(topic, replier)
      one = captured_queries { get "/api/v1/topics/#{topic.id}" }
      2.times { join(topic, create(:alias, :with_sent_messages)) }
      three = captured_queries { get "/api/v1/topics/#{topic.id}" }

      expect(body["participants"].size).to eq(3)
      expect(three.size).to eq(one.size)
    end
  end
end
