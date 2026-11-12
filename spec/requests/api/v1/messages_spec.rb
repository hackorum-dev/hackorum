require "rails_helper"

RSpec.describe "API v1 messages", type: :request do
  let(:alice) { create(:alias, :with_sent_messages, name: "Alice A", email: "alice@example.org") }
  let(:bob) { create(:alias, :with_sent_messages, name: "Bob B", email: "bob@example.org") }
  let(:topic) { create(:topic, creator_alias: alice, title: "Add a feature", slug: "add-feature") }
  let(:start) { Time.zone.parse("2026-03-01 10:00:00") }

  let(:message_keys) do
    %w[id url html_url topic_id number rfc_message_id subject created_at state sender sender_alias reply_to_id depth
       is_patch_submission body attachments me]
  end
  let(:attachment_keys) { %w[id message_id file_name content_type byte_size is_patch url content_url] }

  def body
    JSON.parse(response.body)
  end

  def data
    body["data"]
  end

  def error_code
    body.dig("error", "code")
  end

  def message(at: start, sender: alice, **attrs)
    create(:message, topic: topic, sender: sender, created_at: at, **attrs)
  end

  describe "GET /topics/{id}/messages" do
    it "lists the thread with the documented row without a token" do
      root = message(subject: "Add a feature", message_id: "root@example.org",
                     body: "Here is v1.\n\nOn Mon, Bob wrote:\n> an idea\nDone.\n")
      attachment = create(:attachment, message: root, file_name: "v1-0001-feature.patch",
                                       content_type: "text/x-patch; charset=us-ascii",
                                       body: Base64.encode64("diff --git a/x b/x\n" * 20))
      reply = message(at: start + 1.hour, sender: bob, reply_to: root, state: "pending", message_id: nil)

      get "/api/v1/topics/#{topic.id}/messages"

      expect(response).to have_http_status(:ok)
      expect(response.headers["RateLimit-Limit"]).to be_present
      expect(body.keys).to match_array(%w[data next_cursor])
      expect(body["next_cursor"]).to be_nil
      expect(data.map { |row| row["id"] }).to eq([ root.id, reply.id ])
      row = data.first
      expect(row.keys).to match_array(message_keys)
      expect(row).to include(
        "id" => root.id, "topic_id" => topic.id, "number" => 1, "rfc_message_id" => "root@example.org",
        "subject" => "Add a feature", "created_at" => "2026-03-01T10:00:00.000Z", "state" => "sent",
        "reply_to_id" => nil, "depth" => 0, "is_patch_submission" => true, "body" => "Here is v1.\n\nDone.\n",
        "sender_alias" => { "name" => "Alice A", "email" => "alice@example.org" }
      )
      expect(row["url"]).to end_with("/api/v1/messages/#{root.id}")
      expect(row["html_url"]).to end_with("/topics/#{topic.id}#message-#{root.id}")
      expect(row["html_url"]).not_to include("/api/")
      expect(row["sender"]).to include("id" => alice.person_id, "name" => "Alice A", "email" => "alice@example.org")
      expect(row["attachments"].size).to eq(1)
      expect(row["attachments"].first.keys).to match_array(attachment_keys)
      expect(row["attachments"].first).to include(
        "id" => attachment.id, "message_id" => root.id, "file_name" => "v1-0001-feature.patch",
        "content_type" => "text/x-patch; charset=us-ascii", "byte_size" => 380, "is_patch" => true
      )
      expect(row["attachments"].first["url"]).to end_with("/api/v1/attachments/#{attachment.id}")
      expect(row["attachments"].first["content_url"]).to end_with("/api/v1/attachments/#{attachment.id}/content")
      expect(data.last).to include("number" => 2, "state" => "pending", "rfc_message_id" => nil, "reply_to_id" => root.id,
                                   "depth" => 1, "is_patch_submission" => false, "attachments" => [])
      expect(data.last["sender"]).to include("id" => bob.person_id)
    end

    it "finds the topic by slug and answers an unknown one with 404" do
      message

      get "/api/v1/topics/add-feature/messages"
      expect(response).to have_http_status(:ok)
      expect(data.size).to eq(1)

      get "/api/v1/topics/nope/messages"
      expect(response).to have_http_status(:not_found)
      expect(error_code).to eq("not_found")
    end

    it "gives an empty page for a topic without messages" do
      get "/api/v1/topics/#{topic.id}/messages"

      expect(body).to eq("data" => [], "next_cursor" => nil)
    end

    it "redirects a merged topic and keeps the parameters" do
      source = create(:topic, creator_alias: alice, merged_into_topic_id: topic.id)

      get "/api/v1/topics/#{source.id}/messages?body=none&limit=2"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers["Location"]).to end_with("/api/v1/topics/#{topic.id}/messages?body=none&limit=2")
    end

    it "pages through the thread in order, with numbers that go on" do
      tied = Array.new(3) { message(at: start + 1.hour) }
      first = message(at: start)
      last = message(at: start + 2.hours)
      expected = [ first, *tied, last ].map(&:id)

      seen = []
      cursor = nil
      3.times do
        get "/api/v1/topics/#{topic.id}/messages", params: { limit: 2, cursor: cursor }.compact
        expect(response).to have_http_status(:ok)
        seen.concat(data.map { |row| [ row["id"], row["number"] ] })
        cursor = body["next_cursor"]
      end

      expect(cursor).to be_nil
      expect(seen.map(&:first)).to eq(expected)
      expect(seen.map(&:last)).to eq([ 1, 2, 3, 4, 5 ])
    end

    it "serves the body as asked" do
      stored = "Top.\nOn Tue, Jan 1, 2025 at 10:00 AM Some Body <s@example.com>\nwrote:\n> quoted\nKeep.\n"
      message(body: stored)

      get "/api/v1/topics/#{topic.id}/messages", params: { body: "none" }
      expect(data.first.keys).to match_array(message_keys)
      expect(data.first["body"]).to be_nil

      get "/api/v1/topics/#{topic.id}/messages", params: { body: "text" }
      expect(data.first["body"]).to eq("Top.\nKeep.\n")

      get "/api/v1/topics/#{topic.id}/messages", params: { body: "full" }
      expect(data.first["body"]).to eq(stored)
    end

    it "does not read the bodies for body=none" do
      message
      create(:attachment, message: Message.last)

      queries = captured_queries { get "/api/v1/topics/#{topic.id}/messages", params: { body: "none" } }

      expect(response).to have_http_status(:ok)
      from_messages = queries.grep(/FROM "messages"/)
      expect(from_messages).not_to be_empty
      expect(from_messages.grep(/\*|"messages"\."body"|messages\.body/)).to be_empty
      on_attachments = queries.grep(/\battachments\b/i)
      expect(on_attachments.size).to eq(1)
      expect(on_attachments.grep(/\*|body|decode/i)).to be_empty
    end

    it "takes a cursor only on the topic it came from, with any body and limit" do
      3.times { |i| message(at: start + i.hours, body: "text #{i}") }
      other = create(:topic, creator_alias: alice)
      3.times { |i| create(:message, topic: other, sender: alice, created_at: start + i.hours) }
      get "/api/v1/topics/#{topic.id}/messages", params: { limit: 1, body: "none" }
      cursor = body["next_cursor"]
      expect(data.first["body"]).to be_nil

      get "/api/v1/topics/#{other.id}/messages", params: { limit: 1, body: "none", cursor: cursor }
      expect(response).to have_http_status(:bad_request)
      expect(error_code).to eq("invalid_cursor")

      get "/api/v1/topics/#{topic.id}/patchsets", params: { cursor: cursor }
      expect(error_code).to eq("invalid_cursor")

      get "/api/v1/topics/#{topic.id}/messages", params: { limit: 2, body: "full", cursor: cursor }
      expect(response).to have_http_status(:ok)
      expect(data.map { |row| row["body"] }).to eq([ "text 1", "text 2" ])
    end

    it "rejects an unknown body mode, a NUL and a list" do
      message

      [ "body=html", "body=a%00", "body[]=text", "body=" ].each do |query|
        get "/api/v1/topics/#{topic.id}/messages?#{query}"

        expect(response).to have_http_status(:bad_request), "#{query} gave #{response.status}"
        expect(error_code).to eq("invalid_parameter")
      end

      get "/api/v1/topics/#{topic.id}/messages?limit=0"
      expect(error_code).to eq("invalid_limit")
      get "/api/v1/topics/#{topic.id}/messages?cursor=nope"
      expect(error_code).to eq("invalid_cursor")
    end

    it "follows the reply chain for depth, on every page" do
      other = create(:message, topic: create(:topic, creator_alias: alice), sender: alice)
      root = message
      child = message(at: start + 1.hour, reply_to: root)
      grandchild = message(at: start + 2.hours, reply_to: child)
      outside = message(at: start + 3.hours, reply_to: other)
      under_outside = message(at: start + 4.hours, reply_to: outside)
      early = message(at: start - 1.hour, reply_to: grandchild)

      get "/api/v1/topics/#{topic.id}/messages", params: { limit: 4, body: "none" }
      rows = data
      get "/api/v1/topics/#{topic.id}/messages", params: { limit: 4, body: "none", cursor: body["next_cursor"] }
      rows += data

      expect(rows.map { |row| row["id"] }).to eq([ early, root, child, grandchild, outside, under_outside ].map(&:id))
      expect(rows.map { |row| row["depth"] }).to eq([ 3, 0, 1, 2, 0, 1 ])
      expect(rows.map { |row| row["number"] }).to eq([ 1, 2, 3, 4, 5, 6 ])
      expect(rows[4]["reply_to_id"]).to eq(other.id)
    end

    it "gives a reply loop the same depths wherever the page starts" do
      a = message
      b = message(at: start + 1.hour, reply_to: a)
      c = message(at: start + 2.hours, reply_to: b)
      own = message(at: start + 3.hours)
      a.update_columns(reply_to_id: b.id)
      own.update_columns(reply_to_id: own.id)
      expected = { a.id => 0, b.id => 1, c.id => 2, own.id => 0 }

      get "/api/v1/topics/#{topic.id}/messages", params: { body: "none" }

      expect(response).to have_http_status(:ok)
      expect(data.to_h { |row| [ row["id"], row["depth"] ] }).to eq(expected)

      paged = {}
      cursor = nil
      4.times do
        get "/api/v1/topics/#{topic.id}/messages", params: { body: "none", limit: 1, cursor: cursor }.compact
        paged[data.first["id"]] = data.first["depth"]
        cursor = body["next_cursor"]
      end
      expect(paged).to eq(expected)

      expected.each do |id, depth|
        get "/api/v1/messages/#{id}", params: { body: "none" }
        expect(body["depth"]).to eq(depth), "message #{id} gave #{body['depth']}"
      end
    end

    it "shows the sender's alias next to the person" do
      person = create(:person)
      main = create(:alias, :with_sent_messages, person: person, name: "Carol Main", email: "carol@example.org")
      old = create(:alias, :with_sent_messages, person: person, name: "C. Old", email: "carol@old.example.org")
      person.update!(default_alias: main)
      message(sender: old)

      get "/api/v1/topics/#{topic.id}/messages"

      expect(data.first["sender"]).to include("id" => person.id, "name" => "Carol Main", "email" => "carol@example.org")
      expect(data.first["sender_alias"]).to eq("name" => "C. Old", "email" => "carol@old.example.org")
    end

    it "runs the same queries for one row and for three" do
      first = message
      create(:attachment, message: first)
      one = captured_queries { get "/api/v1/topics/#{topic.id}/messages" }
      expect(data.size).to eq(1)

      2.times do |i|
        reply = message(at: start + (i + 1).hours, sender: create(:alias, :with_sent_messages), reply_to: first)
        create_list(:attachment, 2, message: reply)
      end
      three = captured_queries { get "/api/v1/topics/#{topic.id}/messages" }

      expect(data.size).to eq(3)
      expect(data.map { |row| row["attachments"].size }).to eq([ 1, 2, 2 ])
      expect(three.size).to eq(one.size)
    end
  end

  describe "GET /messages/{id}" do
    it "gives the message with its topic" do
      root = message
      reply = message(at: start + 1.hour, sender: bob, reply_to: root, body: "> q\nYes.\n")
      create(:attachment, :image, message: reply)

      get "/api/v1/messages/#{reply.id}"

      expect(response).to have_http_status(:ok)
      expect(body.keys).to match_array(message_keys + %w[topic])
      expect(body).to include("id" => reply.id, "number" => 2, "depth" => 1, "reply_to_id" => root.id,
                              "body" => "Yes.\n", "topic_id" => topic.id)
      expect(body["topic"].keys).to match_array(%w[id slug title url html_url])
      expect(body["topic"]).to include("id" => topic.id, "slug" => "add-feature", "title" => "Add a feature")
      expect(body["topic"]["url"]).to end_with("/api/v1/topics/#{topic.id}")
      expect(body["topic"]["html_url"]).to end_with("/topics/#{topic.id}")
      expect(body["attachments"].first).to include("file_name" => "screenshot.png", "content_type" => "image/png",
                                                   "byte_size" => 15, "is_patch" => false)
    end

    it "takes the body parameter" do
      shown = message(body: "> q\nYes.\n")

      get "/api/v1/messages/#{shown.id}", params: { body: "none" }
      expect(body["body"]).to be_nil

      get "/api/v1/messages/#{shown.id}", params: { body: "full" }
      expect(body["body"]).to eq("> q\nYes.\n")

      get "/api/v1/messages/#{shown.id}", params: { body: "raw" }
      expect(response).to have_http_status(:bad_request)
      expect(error_code).to eq("invalid_parameter")
    end

    it "serves a message of a merged topic" do
      target = create(:topic, creator_alias: alice)
      topic.update_columns(merged_into_topic_id: target.id)
      kept = message

      get "/api/v1/messages/#{kept.id}"

      expect(response).to have_http_status(:ok)
      expect(body["topic"]["id"]).to eq(topic.id)
    end

    it "answers unknown and non-numeric ids with a JSON 404" do
      %w[0 999999999 99999999999999999999999999 abc 12abc 1.5 -1].each do |id|
        get "/api/v1/messages/#{id}"

        expect(response).to have_http_status(:not_found), "#{id} gave #{response.status}"
        expect(error_code).to eq("not_found")
      end
    end
  end

  describe "GET /messages/lookup" do
    it "finds a Message-ID stored without brackets, however it is written" do
      found = message(message_id: "CAB+x/y%z=1$q@mail.example.org")

      [ "CAB+x/y%z=1$q@mail.example.org", "<CAB+x/y%z=1$q@mail.example.org>" ].each do |value|
        get "/api/v1/messages/lookup", params: { rfc_message_id: value }

        expect(response).to have_http_status(:ok), "#{value} gave #{response.status}"
        expect(body.keys).to match_array(message_keys + %w[topic])
        expect(body).to include("id" => found.id, "rfc_message_id" => "CAB+x/y%z=1$q@mail.example.org", "number" => 1)
        expect(body["message_id"]).to be_nil
      end

      get "/api/v1/messages/lookup?rfc_message_id=CAB%2Bx%2Fy%25z%3D1%24q%40mail.example.org"
      expect(body["id"]).to eq(found.id)
    end

    it "finds a Message-ID stored with brackets" do
      found = message(message_id: "<stored@example.org>")

      [ "stored@example.org", "<stored@example.org>", " <stored@example.org> " ].each do |value|
        get "/api/v1/messages/lookup", params: { rfc_message_id: value }

        expect(response).to have_http_status(:ok), "#{value} gave #{response.status}"
        expect(body["id"]).to eq(found.id)
      end
    end

    it "prefers the id as given" do
      message(message_id: "<twin@example.org>")
      bare = message(at: start + 1.hour, message_id: "twin@example.org")

      get "/api/v1/messages/lookup", params: { rfc_message_id: "twin@example.org" }

      expect(body["id"]).to eq(bare.id)
    end

    it "reads an unencoded plus as a space, as any query string" do
      message(message_id: "a+b@example.org")

      get "/api/v1/messages/lookup?rfc_message_id=a+b@example.org"
      expect(response).to have_http_status(:not_found)

      get "/api/v1/messages/lookup?rfc_message_id=a%2Bb@example.org"
      expect(response).to have_http_status(:ok)
    end

    it "takes the body parameter" do
      message(message_id: "x@example.org", body: "> q\nYes.\n")

      get "/api/v1/messages/lookup", params: { rfc_message_id: "x@example.org", body: "none" }

      expect(body["body"]).to be_nil
    end

    it "answers an unknown id with 404" do
      message

      get "/api/v1/messages/lookup", params: { rfc_message_id: "nobody@example.org" }

      expect(response).to have_http_status(:not_found)
      expect(error_code).to eq("not_found")
    end

    it "does not take the id as message_id" do
      message(message_id: "x@example.org")

      get "/api/v1/messages/lookup", params: { message_id: "x@example.org" }

      expect(response).to have_http_status(:bad_request)
      expect(error_code).to eq("invalid_parameter")
    end

    it "rejects an id over 998 characters and a parameter it does not know" do
      get "/api/v1/messages/lookup", params: { rfc_message_id: "a" * 999 }
      expect(response).to have_http_status(:bad_request)
      expect(error_code).to eq("invalid_parameter")

      get "/api/v1/messages/lookup", params: { rfc_message_id: "a" * 998 }
      expect(response).to have_http_status(:not_found)

      get "/api/v1/messages/lookup", params: { rfc_message_id: "a@example.org", limit: 1 }
      expect(response).to have_http_status(:bad_request)
      expect(error_code).to eq("invalid_parameter")
    end

    it "rejects a missing, blank or unusable id" do
      queries = [ "", "rfc_message_id=", "rfc_message_id=%20", "rfc_message_id=%3C%3E", "rfc_message_id[]=a",
                  "rfc_message_id=a%00b" ]
      queries.each do |query|
        get "/api/v1/messages/lookup?#{query}"

        expect(response).to have_http_status(:bad_request), "#{query.inspect} gave #{response.status}"
        expect(error_code).to eq("invalid_parameter")
      end
    end
  end

  context "with a token" do
    let(:user) { create(:user, username: "alice") }
    let(:other) { create(:user, username: "bob") }
    let(:headers) { bearer(user) }

    def bearer(owner)
      { "Authorization" => "Bearer #{ApiToken.issue!(user: owner, name: 'laptop').last}" }
    end

    def read(first, last = first, by: user, in_topic: topic)
      MessageReadRange.add_range(user: by, topic: in_topic, start_id: first.id, end_id: last.id)
    end

    def flags
      data.map { |row| row["me"] && row["me"]["read"] }
    end

    def without_me(value)
      case value
      when Hash then value.except("me").transform_values { |child| without_me(child) }
      when Array then value.map { |child| without_me(child) }
      else value
      end
    end

    it "gives me as null without a token and the same rows otherwise" do
      messages = Array.new(2) { |i| message(at: start + i.hours, message_id: "m#{i}@example.org") }
      create(:attachment, message: messages.first)
      read(messages.first)
      paths = [ "/api/v1/topics/#{topic.id}/messages", "/api/v1/messages/#{messages.first.id}",
                "/api/v1/messages/lookup?rfc_message_id=m0@example.org" ]

      paths.each do |path|
        get path
        anonymous = body
        rows = anonymous["data"] || [ anonymous ]
        expect(rows).to all(include("me" => nil)), path

        get path, headers: headers
        expect(without_me(body)).to eq(without_me(anonymous)), path
      end
    end

    it "flags the messages the caller read, across pages" do
      messages = Array.new(5) { |i| message(at: start + i.hours) }
      read(messages[0], messages[1])
      read(messages[3])
      read(messages[2], messages[4], by: other)

      seen = []
      cursor = nil
      3.times do
        get "/api/v1/topics/#{topic.id}/messages", params: { limit: 2, cursor: cursor }.compact, headers: headers
        expect(response).to have_http_status(:ok)
        expect(data.map { |row| row["me"].keys }).to all(eq(%w[read]))
        seen.concat(flags)
        cursor = body["next_cursor"]
      end
      expect(seen).to eq([ true, true, false, true, false ])

      get "/api/v1/topics/#{topic.id}/messages", headers: bearer(other)
      expect(flags).to eq([ false, false, true, true, true ])

      get "/api/v1/topics/#{topic.id}/messages", headers: bearer(create(:user))
      expect(flags).to eq([ false, false, false, false, false ])
    end

    it "goes by message id, not by the place in the thread" do
      late = message(at: start + 2.hours)
      early = message(at: start)
      middle = message(at: start + 1.hour)
      read(late, early)

      get "/api/v1/topics/#{topic.id}/messages", headers: headers

      expect(data.map { |row| row["id"] }).to eq([ early.id, middle.id, late.id ])
      expect(flags).to eq([ true, false, true ])
    end

    it "does not take a range of another topic" do
      elsewhere = create(:topic, creator_alias: alice)
      shown = message
      MessageReadRange.create!(user: user, topic: elsewhere, range_start_message_id: shown.id - 1,
                               range_end_message_id: shown.id + 1, message_count: 1, read_at: Time.current)

      get "/api/v1/topics/#{topic.id}/messages", headers: headers

      expect(flags).to eq([ false ])
    end

    it "flags one message by id and by Message-ID" do
      unread = message(message_id: "unread@example.org")
      done = message(at: start + 1.hour, message_id: "done@example.org")
      read(done)
      read(unread, by: other)

      get "/api/v1/messages/#{done.id}", headers: headers
      expect(body["me"]).to eq("read" => true)
      get "/api/v1/messages/#{unread.id}", headers: headers
      expect(body["me"]).to eq("read" => false)
      get "/api/v1/messages/lookup", params: { rfc_message_id: "done@example.org" }, headers: headers
      expect(body["me"]).to eq("read" => true)
      get "/api/v1/messages/lookup", params: { rfc_message_id: "unread@example.org" }, headers: headers
      expect(body["me"]).to eq("read" => false)
      get "/api/v1/messages/#{unread.id}", headers: bearer(other)
      expect(body["me"]).to eq("read" => true)
      get "/api/v1/messages/#{done.id}"
      expect(body["me"]).to be_nil
    end

    it "adds one query, for any number of messages and ranges" do
      messages = [ message ]
      get "/api/v1/me", headers: headers
      anonymous = captured_queries { get "/api/v1/topics/#{topic.id}/messages" }
      one = captured_queries { get "/api/v1/topics/#{topic.id}/messages", headers: headers }
      token_queries = one.grep(/api_tokens|FROM "users"/).size
      expect(one.size - token_queries - anonymous.size).to eq(1)
      expect(one.grep(/message_read_ranges/).size).to eq(1)

      4.times { |i| messages << message(at: start + (i + 1).hours) }
      read(messages[0])
      read(messages[2])
      read(messages[4])
      five = captured_queries { get "/api/v1/topics/#{topic.id}/messages", headers: headers }

      expect(flags).to eq([ true, false, true, false, true ])
      expect(five.size).to eq(one.size)

      single = captured_queries { get "/api/v1/messages/#{messages[2].id}", headers: headers }
      expect(single.grep(/message_read_ranges/).size).to eq(1)
    end

    it "writes nothing" do
      shown = message(message_id: "quiet@example.org")
      attachment = create(:attachment, message: shown)
      user

      queries = captured_queries do
        get "/api/v1/topics/#{topic.id}/messages", headers: headers
        get "/api/v1/messages/#{shown.id}", headers: headers
        get "/api/v1/messages/lookup", params: { rfc_message_id: "quiet@example.org" }, headers: headers
        get "/api/v1/attachments/#{attachment.id}", headers: headers
        get "/api/v1/attachments/#{attachment.id}/content", headers: headers
      end

      expect(response).to have_http_status(:ok)
      expect(ThreadAwareness.count).to eq(0)
      expect(MessageReadRange.count).to eq(0)
      writes = queries.grep(/\A\s*(INSERT|UPDATE|DELETE)/i)
      expect(writes.grep_v(/api_tokens/)).to be_empty
    end
  end
end
