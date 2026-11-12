require "rails_helper"

RSpec.describe "API v1 drafts", type: :request do
  let(:user) { create(:user, username: "alice") }
  let(:other) { create(:user, username: "bob") }
  let!(:identity) { create(:identity, user: user, email: "alice@example.org", refresh_token: "r", send_authorized_at: 1.hour.ago) }
  let!(:sender) { create(:alias, user: user, email: "alice@example.org", name: "Alice A") }
  let(:list) { create(:mailing_list, post_address: "list@example.org") }
  let(:topic) { create(:topic, mailing_lists: [ list ], title: "Add a feature", slug: "add-feature") }
  let(:parent) { create(:message, topic: topic, subject: "Add a feature", created_at: Time.utc(2026, 3, 2, 10)) }
  let(:issued) { ApiToken.issue!(user: user, name: "agent") }
  let(:token) { issued.first }
  let(:auth) { { "Authorization" => "Bearer #{issued.last}" } }
  let(:other_auth) { bearer(other) }
  let(:fixed) { [] }
  let(:detail_keys) do
    %w[id url html_url state topic reply_to_message_id subject body sender recipients recipients_error attachments
       last_send_error created_via last_edited_via sent_message_id sent_at created_at updated_at]
  end
  let(:row_keys) { detail_keys - %w[body recipients recipients_error] }
  let(:path) { "/api/v1/drafts" }

  after do
    expect(OutgoingDraft.where.not(status: "idle").pluck(:id)).to match_array(fixed.map(&:id))
    expect(OutgoingDraft.where.not(sending_started_at: nil).pluck(:id) - fixed.map(&:id)).to eq([])
  end

  around do |example|
    with_env("HACKORUM_DEV_REPLY_TO" => "dev@example.net") { example.run }
  end

  def bearer(owner)
    { "Authorization" => "Bearer #{ApiToken.issue!(user: owner, name: 'laptop').last}" }
  end

  def body
    JSON.parse(response.body)
  end

  def data
    body["data"]
  end

  def error
    body.fetch("error")
  end

  def expect_error(status, code, message = nil)
    expect(response).to have_http_status(status)
    expect(error["code"]).to eq(code)
    expect(error["message"]).to match(message) if message
  end

  def json(headers)
    headers.merge("Content-Type" => "application/json")
  end

  def post_draft(fields, headers: auth)
    post path, params: fields.is_a?(String) ? fields : fields.to_json, headers: json(headers)
  end

  def patch_draft(draft, fields, headers: auth)
    patch "#{path}/#{draft.id}", params: fields.is_a?(String) ? fields : fields.to_json, headers: json(headers)
  end

  # a draft in a state only the site can give it
  def draft_of(owner = user, status: "idle", **attrs)
    attrs = { identity: identity, sender_alias: sender }.merge(attrs) if owner == user
    attrs = { topic: topic, reply_to_message: parent }.merge(attrs)
    attrs[:sending_started_at] ||= 1.minute.ago if status == "sending"
    attrs[:sent_at] ||= 1.minute.ago if status == "sent"
    create(:outgoing_draft, user: owner, status: status, **attrs).tap { |draft| fixed << draft unless status == "idle" }
  end

  def topic_ref(of)
    {
      "id" => of.id, "slug" => of.slug, "title" => of.title,
      "url" => "http://www.example.com/api/v1/topics/#{of.id}", "html_url" => "http://www.example.com/topics/#{of.id}"
    }
  end

  # as in production: the exceptions app answers
  def with_production_errors
    config = Rails.application.env_config
    saved = config.slice("action_dispatch.show_exceptions", "action_dispatch.show_detailed_exceptions")
    config.merge!("action_dispatch.show_exceptions" => :all, "action_dispatch.show_detailed_exceptions" => false)
    yield
  ensure
    config.merge!(saved)
  end

  def unchanged(draft)
    before = draft.reload.attributes
    yield
    expect(draft.reload.attributes).to eq(before)
  end

  describe "the promise not to send" do
    it "has no route that sends or confirms" do
      routes = Rails.application.routes.routes.select { |route| route.path.spec.to_s.start_with?("/api") }
      drafts = routes.select { |route| route.defaults[:controller] == "api/v1/drafts" }

      expect(routes).not_to be_empty
      expect(routes.map { |route| route.defaults[:action] }).not_to include("send_now", "confirm")
      expect(routes.map { |route| route.path.spec.to_s }.grep(/send|confirm/)).to eq([])
      expect(routes.map { |route| route.defaults[:controller] }).not_to include("drafts", "draft_attachments")
      expect(drafts.map { |route| [ route.verb, route.path.spec.to_s.delete_suffix("(.:format)"), route.defaults[:action] ] })
        .to match_array([
          [ "GET", "/api/v1/drafts", "index" ], [ "POST", "/api/v1/drafts", "create" ],
          [ "GET", "/api/v1/drafts/:id", "show" ], [ "PATCH", "/api/v1/drafts/:id", "update" ],
          [ "DELETE", "/api/v1/drafts/:id", "destroy" ]
        ])
    end

    it "leaves the site's send action where it is" do
      expect(Rails.application.routes.recognize_path("/drafts/1/send_now", method: :post))
        .to include(controller: "drafts", action: "send_now")
    end
  end

  describe "without a usable token" do
    let!(:draft) { draft_of(user) }

    def each_operation(headers)
      yield "GET list", -> { get path, headers: headers }
      yield "GET one", -> { get "#{path}/#{draft.id}", headers: headers }
      yield "POST", -> { post_draft({ reply_to_message_id: create(:message, topic: topic).id }, headers: headers) }
      yield "PATCH", -> { patch_draft(draft, { body: "x" }, headers: headers) }
      yield "DELETE", -> { delete "#{path}/#{draft.id}", headers: headers }
    end

    it "answers every operation with token_required" do
      unchanged(draft) do
        each_operation({}) do |name, request|
          request.call

          expect_error(:unauthorized, "token_required")
          expect(response.headers["WWW-Authenticate"]).to eq("Bearer"), name
        end
      end
      expect(OutgoingDraft.count).to eq(1)
    end

    it "answers every operation with invalid_token for a revoked token" do
      token.revoke!

      unchanged(draft) do
        each_operation(auth) do |_, request|
          request.call

          expect_error(:unauthorized, "invalid_token")
        end
      end
      expect(OutgoingDraft.count).to eq(1)
    end
  end

  describe "GET /drafts/{id}" do
    it "gives the documented draft" do
      draft = draft_of(user, subject: "Re: Add a feature", body: "My answer")

      get "#{path}/#{draft.id}", headers: auth

      expect(response).to have_http_status(:ok)
      expect(body).to eq(
        "id" => draft.id,
        "url" => "http://www.example.com/api/v1/drafts/#{draft.id}",
        "html_url" => "http://www.example.com/topics/#{topic.id}#message-#{parent.id}",
        "state" => "in_progress",
        "topic" => topic_ref(topic),
        "reply_to_message_id" => parent.id,
        "subject" => "Re: Add a feature",
        "body" => "My answer",
        "sender" => { "name" => "Alice A", "email" => "alice@example.org" },
        "recipients" => { "to" => [ "dev@example.net" ], "cc" => [] },
        "recipients_error" => nil,
        "attachments" => [],
        "last_send_error" => nil,
        "created_via" => nil,
        "last_edited_via" => nil,
        "sent_message_id" => nil,
        "sent_at" => nil,
        "created_at" => draft.created_at.as_json,
        "updated_at" => draft.updated_at.as_json
      )
      expect(body.keys).to eq(detail_keys)
      expect(response.headers["Vary"].to_s).to include("Authorization")
      expect(response.headers["Cache-Control"].to_s).not_to include("public")
    end

    it "gives the recipients the send would use" do
      draft = draft_of(user)
      allow(Outgoing::RecipientResolver).to receive(:for).with(draft).and_return(
        Outgoing::RecipientResolver::Recipients.new(to: [ "Bob <bob@example.org>" ], cc: [ "list@example.org", "Carol <carol@example.org>" ])
      )

      get "#{path}/#{draft.id}", headers: auth

      expect(body["recipients"]).to eq("to" => [ "Bob <bob@example.org>" ], "cc" => [ "list@example.org", "Carol <carol@example.org>" ])
      expect(body["recipients_error"]).to be_nil
    end

    it "says in neutral words why there are no recipients" do
      draft = draft_of(user)
      create(:mailing_list, post_address: "real@list.example")
      cases = [
        [ { "HACKORUM_DEV_REPLY_TO" => nil }, "sending is not configured in this environment" ],
        [ { "HACKORUM_DEV_REPLY_TO" => "real@list.example" }, "sending is not configured in this environment" ]
      ]

      cases.each do |env, message|
        with_env(env) { get "#{path}/#{draft.id}", headers: auth }

        expect(response).to have_http_status(:ok)
        expect(body.slice("recipients", "recipients_error")).to eq("recipients" => nil, "recipients_error" => message)
        expect(response.body).not_to include("HACKORUM", "real@list.example")
      end

      allow(Outgoing::RecipientResolver).to receive(:for)
        .and_raise(Outgoing::RecipientResolver::MissingPostAddressError, "no post_address for secret@list.example")
      get "#{path}/#{draft.id}", headers: auth

      expect(body.slice("recipients", "recipients_error"))
        .to eq("recipients" => nil, "recipients_error" => "the mailing list is not set up for sending")
      expect(response.body).not_to include("secret@list.example")
    end

    it "gives the four states" do
      second, third, fourth = Array.new(3) { create(:message, topic: topic) }
      sent_message = create(:message, topic: topic, reply_to: fourth)
      sent_at = Time.utc(2026, 3, 3, 12, 0, 0)
      drafts = {
        "in_progress" => draft_of(user),
        "failed" => draft_of(user, reply_to_message: second, last_send_error: "Gmail said no"),
        "sending" => draft_of(user, status: "sending", reply_to_message: third),
        "sent" => draft_of(user, status: "sent", reply_to_message: fourth, sent_message: sent_message, sent_at: sent_at)
      }

      drafts.each do |state, draft|
        get "#{path}/#{draft.id}", headers: auth

        expect(response).to have_http_status(:ok)
        expect(body["state"]).to eq(state)
      end
      expect(body).to include("sent_message_id" => sent_message.id, "sent_at" => "2026-03-03T12:00:00.000Z",
                              "html_url" => "http://www.example.com/drafts/#{drafts['sent'].id}")
      get "#{path}/#{drafts['failed'].id}", headers: auth
      expect(body).to include("last_send_error" => "Gmail said no", "sent_message_id" => nil, "sent_at" => nil)
    end

    it "names the tokens that made and last edited it, a revoked one too" do
      editor = ApiToken.issue!(user: user, name: "second agent").first
      draft = draft_of(user, created_via_token: token, last_edited_via_token: editor)
      editor.revoke!

      get "#{path}/#{draft.id}", headers: auth

      expect(body["created_via"]).to eq("token_name" => "agent")
      expect(body["last_edited_via"]).to eq("token_name" => "second agent")

      editor.delete
      get "#{path}/#{draft.id}", headers: auth

      expect(body["created_via"]).to eq("token_name" => "agent")
      expect(body["last_edited_via"]).to be_nil
    end

    it "lists the attachments without their content" do
      draft = draft_of(user)
      first = create(:draft_attachment, outgoing_draft: draft, file_name: "v1-0001-fix.patch", content: "SECRETCONTENT")
      second = create(:draft_attachment, outgoing_draft: draft, file_name: "notes.txt", content_type: nil, content: "ab")
      create(:draft_attachment, outgoing_draft: draft_of(other))

      get "#{path}/#{draft.id}", headers: auth

      expect(body["attachments"]).to eq([
        { "id" => first.id, "file_name" => "v1-0001-fix.patch", "content_type" => "text/x-diff", "byte_size" => 13 },
        { "id" => second.id, "file_name" => "notes.txt", "content_type" => nil, "byte_size" => 2 }
      ])
      expect(response.body).not_to include(Base64.strict_encode64("SECRETCONTENT"))
    end

    it "does not give the draft of another user, or one that does not exist" do
      foreign = draft_of(other, subject: "Re: Bob's secret")

      get "#{path}/#{foreign.id}", headers: auth
      expect_error(:not_found, "not_found")
      expect(response.body).not_to include("secret")

      get "#{path}/#{foreign.id}", headers: other_auth
      expect(response).to have_http_status(:ok)
      expect(body["subject"]).to eq("Re: Bob's secret")

      [ foreign.id + 1000, "9" * 30, "abc" ].each do |id|
        get "#{path}/#{id}", headers: auth
        expect_error(:not_found, "not_found")
      end
    end

    it "takes no parameters and writes nothing" do
      draft = draft_of(user)

      get "#{path}/#{draft.id}", params: { body: "none" }, headers: auth
      expect_error(:bad_request, "invalid_parameter")

      queries = captured_queries { get "#{path}/#{draft.id}", headers: auth }
      expect(response).to have_http_status(:ok)
      expect(queries.grep(/\A\s*(INSERT|UPDATE|DELETE)/i).grep_v(/api_tokens/)).to be_empty
    end
  end

  describe "GET /drafts" do
    let(:start) { Time.utc(2026, 3, 1, 10) }
    let(:parents) { Array.new(4) { create(:message, topic: topic) } }

    def at(draft, time)
      OutgoingDraft.where(id: draft.id).update_all(updated_at: time)
      draft
    end

    def ids(headers = auth, **params)
      get path, params: params, headers: headers
      expect(response).to have_http_status(:ok)
      data.map { |row| row["id"] }
    end

    it "lists the caller's drafts, last changed first, without the text" do
      old = at(draft_of(user, reply_to_message: parents[0], body: "SECRETTEXT"), start)
      tie_low = at(draft_of(user, reply_to_message: parents[1]), start + 1.hour)
      tie_high = at(draft_of(user, reply_to_message: parents[2], created_via_token: token), start + 1.hour)
      sent = at(draft_of(user, status: "sent", reply_to_message: parents[3], sent_at: start - 1.day), start + 2.hours)
      create(:draft_attachment, outgoing_draft: old, file_name: "a.patch", content: "abc")
      foreign = draft_of(other, subject: "Re: Bob's secret")

      expect(ids).to eq([ sent.id, tie_high.id, tie_low.id, old.id ])
      expect(body.keys).to match_array(%w[data next_cursor])
      expect(body["next_cursor"]).to be_nil
      expect(data.map(&:keys)).to all(eq(row_keys))
      expect(data.last).to include(
        "state" => "in_progress", "topic" => topic_ref(topic), "reply_to_message_id" => parents[0].id,
        "sender" => { "name" => "Alice A", "email" => "alice@example.org" },
        "url" => "http://www.example.com/api/v1/drafts/#{old.id}", "updated_at" => "2026-03-01T10:00:00.000Z"
      )
      expect(data.last["attachments"].map { |file| file["file_name"] }).to eq([ "a.patch" ])
      expect(data[1]["created_via"]).to eq("token_name" => "agent")
      expect(response.body).not_to include("SECRETTEXT", "secret")
      expect(response.headers["Vary"].to_s).to include("Authorization")
      expect(response.headers["Cache-Control"].to_s).not_to include("public")

      expect(ids(other_auth)).to eq([ foreign.id ])
    end

    it "filters by state" do
      drafts = {
        "in_progress" => draft_of(user, reply_to_message: parents[0]),
        "failed" => draft_of(user, reply_to_message: parents[1], last_send_error: "no"),
        "sending" => draft_of(user, status: "sending", reply_to_message: parents[2]),
        "sent" => draft_of(user, status: "sent", reply_to_message: parents[3])
      }
      draft_of(other, status: "sent")

      drafts.each do |state, draft|
        expect(ids(state: state)).to eq([ draft.id ]), state
        expect(data.first["state"]).to eq(state)
      end
      expect(ids.size).to eq(4)

      %w[all idle SENT].each do |value|
        get path, params: { state: value }, headers: auth
        expect_error(:bad_request, "invalid_parameter", /state/)
      end
      get path, params: { state: "sent", page: 2 }, headers: auth
      expect_error(:bad_request, "invalid_parameter", /page/)
    end

    it "pages, with cursors that belong to the caller" do
      rows = parents.first(3).each_with_index.map { |message, i| at(draft_of(user, reply_to_message: message), start + i.hours) }
      at(draft_of(other), start)

      expect(ids(limit: 2)).to eq([ rows[2].id, rows[1].id ])
      cursor = body["next_cursor"]
      expect(cursor).to be_present
      expect(ids(limit: 2, cursor: cursor)).to eq([ rows[0].id ])
      expect(body["next_cursor"]).to be_nil
      expect(ids(bearer(user), limit: 2, cursor: cursor)).to eq([ rows[0].id ])

      get path, params: { limit: 2, cursor: cursor }, headers: other_auth
      expect_error(:bad_request, "invalid_cursor")
      get path, params: { limit: 2, cursor: cursor, state: "sent" }, headers: auth
      expect_error(:bad_request, "invalid_cursor")
    end

    it "runs the same queries for one draft and for three" do
      get "/api/v1/me", headers: auth
      first = draft_of(user, reply_to_message: parents[0], created_via_token: token,
                             last_edited_via_token: ApiToken.issue!(user: user, name: "editor").first)
      create(:draft_attachment, outgoing_draft: first)
      one = captured_queries { get path, headers: auth }
      expect(data.size).to eq(1)

      2.times do |i|
        elsewhere = create(:topic, mailing_lists: [ list ])
        extra = draft_of(user, topic: elsewhere, reply_to_message: create(:message, topic: elsewhere),
                               sender_alias: create(:alias, user: user), last_edited_via_token: ApiToken.issue!(user: user, name: "t#{i}").first)
        create_list(:draft_attachment, 2, outgoing_draft: extra)
      end
      three = captured_queries { get path, headers: auth }

      expect(data.size).to eq(3)
      expect(data.map { |row| row["attachments"].size }).to match_array([ 1, 2, 2 ])
      expect(three.size).to eq(one.size)
      expect(three.grep(/\A\s*(INSERT|UPDATE|DELETE)/i).grep_v(/api_tokens/)).to be_empty
    end
  end

  describe "POST /drafts" do
    it "makes a draft with the defaults of the site's composer" do
      parent.update!(subject: "RE: Add a feature")

      expect { post_draft({ reply_to_message_id: parent.id }) }.to change(OutgoingDraft, :count).by(1)

      expect(response).to have_http_status(:created)
      draft = OutgoingDraft.find(body["id"])
      expect(draft).to have_attributes(user: user, topic: topic, reply_to_message: parent, identity: identity, sender_alias: sender,
                                       subject: "Re: Add a feature", body: "", status: "idle",
                                       created_via_token: token, last_edited_via_token: nil)
      expect(body.keys).to eq(detail_keys)
      expect(body).to include(
        "state" => "in_progress", "subject" => "Re: Add a feature", "body" => "", "reply_to_message_id" => parent.id,
        "created_via" => { "token_name" => "agent" }, "last_edited_via" => nil, "attachments" => [],
        "recipients" => { "to" => [ "dev@example.net" ], "cc" => [] },
        "html_url" => "http://www.example.com/topics/#{topic.id}#message-#{parent.id}"
      )

      get body["url"].delete_prefix("http://www.example.com"), headers: auth
      expect(response).to have_http_status(:ok)
      expect(body["id"]).to eq(draft.id)
    end

    it "takes a subject, a body and a quote that goes in front of the body" do
      display = parent.sender_display_alias

      post_draft({ reply_to_message_id: parent.id, subject: "Re: my own subject", body: "I agree.\n", quote: "first line\nsecond" })

      expect(response).to have_http_status(:created)
      expect(body["subject"]).to eq("Re: my own subject")
      expect(body["body"]).to eq("On Mon, 02 Mar 2026, #{display.name} <#{display.email}> wrote:\n> first line\n> second\n\nI agree.\n")
      expect(OutgoingDraft.find(body["id"]).body).to eq(body["body"])
    end

    it "gives the active draft of the message back with 200 and leaves it alone" do
      post_draft({ reply_to_message_id: parent.id, body: "first text" })
      first = OutgoingDraft.find(body["id"])

      unchanged(first) do
        expect { post_draft({ reply_to_message_id: parent.id, subject: "Re: other", body: "second text", quote: "q" }, headers: bearer(user)) }
          .not_to change(OutgoingDraft, :count)
      end

      expect(response).to have_http_status(:ok)
      expect(body).to include("id" => first.id, "body" => "first text", "subject" => "Re: Add a feature",
                              "created_via" => { "token_name" => "agent" })
    end

    it "gives a draft made on the site back as well, and a new one after a sent one" do
      made_on_site = draft_of(user, body: "typed in the browser")

      unchanged(made_on_site) { post_draft({ reply_to_message_id: parent.id, body: "x" }) }
      expect(response).to have_http_status(:ok)
      expect(body).to include("id" => made_on_site.id, "created_via" => nil)

      made_on_site.update_columns(status: "sent", sent_at: Time.current)
      fixed << made_on_site
      post_draft({ reply_to_message_id: parent.id })

      expect(response).to have_http_status(:created)
      expect(body["id"]).not_to eq(made_on_site.id)
    end

    it "keeps the drafts of two users for one message apart" do
      foreign = draft_of(other, body: "Bob's text")

      unchanged(foreign) { post_draft({ reply_to_message_id: parent.id }) }

      expect(response).to have_http_status(:created)
      expect(body["id"]).not_to eq(foreign.id)
      expect(response.body).not_to include("Bob's text")
    end

    it "needs an account that can send" do
      post_draft({ reply_to_message_id: parent.id }, headers: other_auth)
      expect_error(:forbidden, "no_send_identity", /Gmail/)

      identity.update!(send_revoked_at: Time.current)
      post_draft({ reply_to_message_id: parent.id })
      expect_error(:forbidden, "no_send_identity")

      identity.update!(send_revoked_at: nil)
      sender.update!(email: "elsewhere@example.org")
      post_draft({ reply_to_message_id: parent.id })
      expect_error(:forbidden, "no_send_identity", /address/)

      expect(OutgoingDraft.count).to eq(0)
    end

    it "answers an unknown message with 404" do
      post_draft({ reply_to_message_id: parent.id + 1000 })

      expect_error(:not_found, "not_found")
      expect(OutgoingDraft.count).to eq(0)
    end

    it "says that a draft without a message to reply to is not supported yet" do
      post_draft({ subject: "A new thread", body: "Hello" })

      expect_error(:unprocessable_content, "invalid_body", /reply_to_message_id.*start a thread.*not supported yet/)
      expect(OutgoingDraft.count).to eq(0)
    end

    it "refuses a body it does not understand, naming the field" do
      id = parent.id
      cases = {
        { reply_to_message_id: id, to: "x@example.org" } => /unknown field: to/,
        { reply_to_message_id: id, updated_at: Time.current.iso8601 } => /unknown field: updated_at/,
        { reply_to_message_id: id, draft: { subject: "x" } } => /unknown field: draft/,
        { reply_to_message_id: id.to_s } => /reply_to_message_id must be a positive integer/,
        { reply_to_message_id: 0 } => /reply_to_message_id must be a positive integer/,
        { reply_to_message_id: 2**63 } => /reply_to_message_id must be a positive integer/,
        { reply_to_message_id: 1.5 } => /reply_to_message_id must be a positive integer/,
        { reply_to_message_id: nil } => /reply_to_message_id must be a positive integer/,
        { reply_to_message_id: id, subject: 5 } => /subject must be a string/,
        { reply_to_message_id: id, subject: nil } => /subject must be a string/,
        { reply_to_message_id: id, subject: " " } => /subject must not be blank/,
        { reply_to_message_id: id, subject: "a\nBcc: x@example.org" } => /subject must be a single line/,
        { reply_to_message_id: id, subject: "a" * 999 } => /subject is too long, at most 998 characters/,
        { reply_to_message_id: id, body: [ "a" ] } => /body must be a string/,
        { reply_to_message_id: id, body: { text: "a" } } => /body must be a string/,
        { reply_to_message_id: id, body: "a\u0000b" } => /body has a NUL byte/,
        { reply_to_message_id: id, body: "a" * (1.megabyte + 1) } => /body is too long, at most 1048576 bytes/,
        { reply_to_message_id: id, body: "é" * (1.megabyte / 2 + 1) } => /body is too long/,
        { reply_to_message_id: id, quote: true } => /quote must be a string/,
        { reply_to_message_id: id, quote: "a" * (100.kilobytes + 1) } => /quote is too long, at most 102400 bytes/,
        "[]" => /must be a JSON object/,
        "[{\"reply_to_message_id\": #{id}}]" => /must be a JSON object/,
        "\"text\"" => /must be a JSON object/,
        "null" => /must be a JSON object/,
        "" => /must be a JSON object/
      }

      cases.each do |fields, message|
        post_draft(fields)

        expect(response).to have_http_status(:unprocessable_content), fields.to_s.first(80)
        expect(error["code"]).to eq("invalid_body")
        expect(error["message"]).to match(message)
        expect(error["message"].length).to be < 200
      end
      expect(OutgoingDraft.count).to eq(0)
    end

    it "takes values at the limits" do
      post_draft({ reply_to_message_id: parent.id, subject: "é" * 998, body: "a" * 1.megabyte })

      expect(response).to have_http_status(:created)
      expect(OutgoingDraft.find(body["id"]).subject.length).to eq(998)

      post_draft({ reply_to_message_id: create(:message, topic: topic).id, body: "a", quote: "q" * 100.kilobytes })

      expect(response).to have_http_status(:created)
    end

    it "takes JSON only" do
      fields = { reply_to_message_id: parent.id }
      [
        [ fields, { "Content-Type" => "application/x-www-form-urlencoded" } ],
        [ fields.to_json, { "Content-Type" => "text/plain" } ],
        [ fields.to_json, { "Content-Type" => "application/vnd.api+json" } ],
        [ fields.to_json, {} ]
      ].each do |params, type|
        post path, params: params, headers: auth.merge(type)

        expect_error(:unsupported_media_type, "unsupported_media_type", %r{application/json})
      end
      expect(OutgoingDraft.count).to eq(0)

      post path, params: fields.to_json, headers: auth.merge("Content-Type" => "application/json; charset=utf-8")
      expect(response).to have_http_status(:created)
    end

    it "answers malformed JSON with bad_request" do
      with_production_errors { post_draft("{\"reply_to_message_id\": ") }

      expect_error(:bad_request, "bad_request")
      expect(response.media_type).to eq("application/json")
      expect(OutgoingDraft.count).to eq(0)
    end

    it "takes nothing from the query string" do
      post "#{path}?reply_to_message_id=#{parent.id}", params: "{}", headers: json(auth)
      expect_error(:bad_request, "invalid_parameter", /reply_to_message_id/)

      post "#{path}?subject=x", params: { reply_to_message_id: parent.id }.to_json, headers: json(auth)
      expect_error(:bad_request, "invalid_parameter", /subject/)
      expect(OutgoingDraft.count).to eq(0)
    end
  end

  describe "PATCH /drafts/{id}" do
    let!(:draft) { draft_of(user, subject: "Re: Add a feature", body: "first", created_at: 1.hour.ago, updated_at: 1.hour.ago) }

    it "changes subject and body and says which token did it" do
      patch_draft(draft, { subject: "Re: Add a better feature", body: "second" })

      expect(response).to have_http_status(:ok)
      expect(body.keys).to eq(detail_keys)
      expect(body).to include("id" => draft.id, "subject" => "Re: Add a better feature", "body" => "second",
                              "created_via" => nil, "last_edited_via" => { "token_name" => "agent" }, "state" => "in_progress")
      was = draft.updated_at
      expect(draft.reload).to have_attributes(subject: "Re: Add a better feature", body: "second", last_edited_via_token: token)
      expect(draft.updated_at).to be > was
      expect(body["updated_at"]).to eq(draft.updated_at.as_json)

      patch_draft(draft, { body: "" })
      expect(response).to have_http_status(:ok)
      expect(draft.reload).to have_attributes(subject: "Re: Add a better feature", body: "")
    end

    it "does nothing for an empty object or for the values it has" do
      [ {}, { subject: "Re: Add a feature", body: "first" }, { updated_at: draft.updated_at.as_json } ].each do |fields|
        unchanged(draft) { patch_draft(draft, fields) }

        expect(response).to have_http_status(:ok)
        expect(body).to include("id" => draft.id, "last_edited_via" => nil)
      end
    end

    it "takes the updated_at the client saw last and refuses a stale one" do
      get "#{path}/#{draft.id}", headers: auth
      seen = body["updated_at"]

      patch_draft(draft, { body: "second", updated_at: seen })
      expect(response).to have_http_status(:ok)
      current = body["updated_at"]
      expect(current).not_to eq(seen)

      unchanged(draft) { patch_draft(draft, { body: "third", updated_at: seen }) }
      expect_error(:conflict, "conflict", /changed/)

      patch_draft(draft, { body: "third", updated_at: Time.iso8601(current).localtime("+02:00").iso8601(3) })
      expect(response).to have_http_status(:ok)
      expect(draft.reload.body).to eq("third")
    end

    it "refuses a draft that is being sent, and a sent one" do
      draft.update_columns(status: "sending", sending_started_at: Time.current)
      fixed << draft
      unchanged(draft) { patch_draft(draft, { body: "x" }) }
      expect_error(:conflict, "conflict", /being sent/)

      draft.update_columns(status: "sent", sent_at: Time.current, sending_started_at: nil)
      unchanged(draft) { patch_draft(draft, { body: "x" }) }
      expect_error(:unprocessable_content, "invalid_body", /sent/)
      unchanged(draft) { patch_draft(draft, {}) }
      expect_error(:unprocessable_content, "invalid_body", /sent/)
    end

    it "refuses a body it does not understand" do
      cases = {
        { subject: "" } => /subject must not be blank/,
        { subject: "  " } => /subject must not be blank/,
        { subject: nil } => /subject must be a string/,
        { subject: "a" * 999 } => /subject is too long/,
        { body: nil } => /body must be a string/,
        { body: "a" * (1.megabyte + 1) } => /body is too long/,
        { quote: "x" } => /unknown field: quote/,
        { reply_to_message_id: parent.id } => /unknown field: reply_to_message_id/,
        { status: "sending" } => /unknown field: status/,
        { outgoing_draft: { body: "x" } } => /unknown field: outgoing_draft/,
        { updated_at: "yesterday" } => /updated_at must be an ISO 8601 timestamp/,
        { updated_at: 5 } => /updated_at must be an ISO 8601 timestamp/,
        "[]" => /must be a JSON object/
      }

      unchanged(draft) do
        cases.each do |fields, message|
          patch_draft(draft, fields)

          expect(response).to have_http_status(:unprocessable_content), fields.to_s.first(80)
          expect(error["code"]).to eq("invalid_body")
          expect(error["message"]).to match(message)
        end
      end
    end

    it "does not touch the draft of another user" do
      foreign = draft_of(other, reply_to_message: create(:message, topic: topic))

      unchanged(foreign) { patch_draft(foreign, { body: "taken over" }) }
      expect_error(:not_found, "not_found")

      patch_draft(foreign, { body: "Bob's own" }, headers: other_auth)
      expect(response).to have_http_status(:ok)
      expect(foreign.reload.body).to eq("Bob's own")

      patch_draft(OutgoingDraft.new(id: foreign.id + 1000), { body: "x" })
      expect_error(:not_found, "not_found")
    end

    it "takes JSON only, and nothing from the query string" do
      unchanged(draft) do
        patch "#{path}/#{draft.id}", params: { body: "x" }, headers: auth
        expect_error(:unsupported_media_type, "unsupported_media_type")

        patch "#{path}/#{draft.id}?body=x", params: "{}", headers: json(auth)
        expect_error(:bad_request, "invalid_parameter")

        with_production_errors { patch_draft(draft, "{\"body\": \"x\"") }
        expect_error(:bad_request, "bad_request")
      end
    end

    it "keeps nothing of a request that ends in an error" do
      allow_any_instance_of(OutgoingDraft).to receive(:save) do |record|
        record.update_columns(body: "half done")
        false
      end

      unchanged(draft) { patch_draft(draft, { body: "second" }) }

      expect_error(:unprocessable_content, "invalid_body")
    end
  end

  describe "DELETE /drafts/{id}" do
    let!(:draft) { draft_of(user) }

    it "deletes the draft and its attachments" do
      attachment = create(:draft_attachment, outgoing_draft: draft)

      delete "#{path}/#{draft.id}", headers: auth

      expect(response).to have_http_status(:no_content)
      expect(response.body).to eq("")
      expect(OutgoingDraft.exists?(draft.id)).to be(false)
      expect(DraftAttachment.exists?(attachment.id)).to be(false)

      delete "#{path}/#{draft.id}", headers: auth
      expect_error(:not_found, "not_found")

      post_draft({ reply_to_message_id: parent.id })
      expect(response).to have_http_status(:created)
    end

    it "refuses a draft that is being sent, and a sent one" do
      draft.update_columns(status: "sending", sending_started_at: Time.current)
      fixed << draft
      delete "#{path}/#{draft.id}", headers: auth
      expect_error(:conflict, "conflict", /being sent/)

      draft.update_columns(status: "sent", sent_at: Time.current, sending_started_at: nil)
      delete "#{path}/#{draft.id}", headers: auth
      expect_error(:unprocessable_content, "unprocessable_content", /sent/)

      expect(OutgoingDraft.exists?(draft.id)).to be(true)
    end

    it "does not delete the draft of another user" do
      foreign = draft_of(other)

      delete "#{path}/#{foreign.id}", headers: auth
      expect_error(:not_found, "not_found")
      expect(OutgoingDraft.exists?(foreign.id)).to be(true)

      delete "#{path}/#{foreign.id}", headers: other_auth
      expect(response).to have_http_status(:no_content)
      expect(OutgoingDraft.exists?(draft.id)).to be(true)
    end

    it "takes no parameters" do
      delete "#{path}/#{draft.id}?force=true", headers: auth

      expect_error(:bad_request, "invalid_parameter")
      expect(OutgoingDraft.exists?(draft.id)).to be(true)
    end
  end

  describe "the limit on drafts that are not sent" do
    let(:limit) { Drafts::TokenLimits::ACTIVE_DRAFTS }

    def fill(count, **attrs)
      count.times { draft_of(user, reply_to_message: create(:message, topic: topic), **attrs) }
    end

    it "refuses a new draft at 50, and says how to make room" do
      expect(limit).to eq(50)
      fill(limit - 1)

      post_draft({ reply_to_message_id: parent.id })
      expect(response).to have_http_status(:created)

      expect { post_draft({ reply_to_message_id: create(:message, topic: topic).id }) }.not_to change(OutgoingDraft, :count)
      expect_error(:unprocessable_content, "draft_limit", /50 drafts.*send or delete/)
    end

    it "still gives an existing draft back, and takes changes and removals" do
      fill(limit)
      existing = user.outgoing_drafts.first

      post_draft({ reply_to_message_id: existing.reply_to_message_id })
      expect(response).to have_http_status(:ok)
      expect(body["id"]).to eq(existing.id)

      patch_draft(existing, { body: "more" })
      expect(response).to have_http_status(:ok)

      delete "#{path}/#{existing.id}", headers: auth
      expect(response).to have_http_status(:no_content)
      post_draft({ reply_to_message_id: parent.id })
      expect(response).to have_http_status(:created)
    end

    it "does not count sent drafts, or the drafts of others" do
      fill(limit - 1)
      fill(3, status: "sent")
      3.times { draft_of(other, reply_to_message: create(:message, topic: topic)) }

      post_draft({ reply_to_message_id: parent.id })

      expect(response).to have_http_status(:created)
    end

    it "does not limit the composer of the site" do
      fill(limit)
      sign_in_as(user)

      expect { post "/drafts", params: { reply_to_message_id: parent.id }, as: :json }.to change(OutgoingDraft, :count).by(1)
      expect(response).to have_http_status(:ok)
      expect(user.outgoing_drafts.count).to eq(limit + 1)
    end
  end

  describe "the size of the stored text" do
    let(:limit) { Api::V1::DraftsController::BODY_BYTES }

    it "counts the quote and its header with the body, as a PATCH would" do
      quote = "q" * 1000

      expect { post_draft({ reply_to_message_id: parent.id, body: "b" * (limit - 500), quote: quote }) }
        .not_to change(OutgoingDraft, :count)
      expect_error(:unprocessable_content, "invalid_body", /body with the quote is too long, at most 1048576 bytes/)

      post_draft({ reply_to_message_id: parent.id, body: "b" * (limit - 2000), quote: quote })
      expect(response).to have_http_status(:created)
      stored = OutgoingDraft.find(body["id"])
      expect(stored.body.bytesize).to be <= limit

      patch_draft(stored, { body: stored.body })
      expect(response).to have_http_status(:ok)
    end

    it "takes a stored text of exactly the limit" do
      post_draft({ reply_to_message_id: parent.id, quote: "q" })
      header = OutgoingDraft.find(body["id"]).body.bytesize
      other_parent = create(:message, topic: topic, created_at: parent.created_at, sender: parent.sender)

      post_draft({ reply_to_message_id: other_parent.id, quote: "q", body: "b" * (limit - header + 1) })
      expect_error(:unprocessable_content, "invalid_body", /too long/)
    end
  end
end
