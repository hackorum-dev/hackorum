require "rails_helper"

RSpec.describe "API v1 events", type: :request do
  let(:alice) { create(:alias, :with_sent_messages, name: "Alice A", email: "alice.a@example.org") }
  let(:bob) { create(:alias, :with_sent_messages, name: "Bob B", email: "bob@example.org") }
  let(:topic) { create(:topic, creator_alias: alice, title: "Add a feature", slug: "add-feature") }
  let(:start) { Time.zone.parse("2026-03-01 10:00:00") }

  let(:event_keys) { %w[id type occurred_at recorded_at topic author] }
  let(:message_keys) do
    %w[id url html_url topic_id number rfc_message_id subject created_at state sender sender_alias reply_to_id depth
       is_patch_submission body attachments me]
  end
  let(:patchset_keys) do
    %w[message_id number url html_url created_at subject sender topic files changed_paths branch download_url]
  end
  let(:branch_keys) do
    %w[id url html_url branch_name topic message_id status failure_stage failure_reason conflict_files
       state state_reason superseded base_sha base_source base_committed_at on_master pg_major behind attempted_at pushed_at
       pushed_head_sha github_url git_url last_master_apply_at master_apply_sha master_apply_error master_conflict_files
       ci_status ci_skip_reason latest_run created_at updated_at]
  end
  let(:run_keys) do
    %w[id github_run_id run_attempt status head_sha pg_major queued_at started_at completed_at build_seconds
       test_seconds tests_total failed_tests image_ref image_pull_ref image_digest created_at github_url branch
       first_run previous_status]
  end
  let(:payload_keys) { %w[message patchset branch ci_run] }

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

  def bearer(owner)
    { "Authorization" => "Bearer #{ApiToken.issue!(user: owner, name: 'laptop').last}" }
  end

  # a patchset with its branch and a finished run: one event of each type but message.received
  def patch_events(in_topic: topic, sender: alice, at: start)
    posted = patchset_event(topic: in_topic, sender: sender, created_at: at)
    row = create(:patch_branch, topic: in_topic, message: posted.message, pushed_at: at, attempted_at: at + 1.minute,
                                base_committed_at: at)
    created = recorded { FeedEvents::Recorder.branch_created(row) }
    completed = ci_event(row, completed_at: at + 1.hour, payload: { "secret" => "x" * 50 })
    row.update_columns(latest_ci_run_id: completed.patch_ci_run_id, ci_status: "success")
    [ posted, created, completed ]
  end

  describe "GET /events" do
    it "gives each type its documented row, oldest first, without a token" do
      create(:patch_ci_repo_state, master_committed_at: start + 3.days)
      received = message_event(topic: topic, sender: bob, created_at: start - 1.hour, subject: "Add a feature",
                               message_id: "root@example.org", at: 30.minutes.ago)
      posted, created, completed = patch_events

      get "/api/v1/events"

      expect(response).to have_http_status(:ok)
      expect(response.headers["RateLimit-Limit"]).to be_present
      expect(response.headers["Vary"].to_s).to include("Authorization")
      expect(body.keys).to match_array(%w[data next_cursor has_more])
      expect(body["has_more"]).to be(false)
      expect(body["next_cursor"]).to eq(Api::EventFeed.encode(completed.id))
      expect(ids).to eq([ received.id, posted.id, created.id, completed.id ])
      expect(data.map { |row| row["type"] }).to eq(%w[message.received patchset.posted branch.created ci.completed])
      expect(data.map { |row| row.keys - event_keys }).to eq(payload_keys.map { |key| [ key ] })

      first, second, third, fourth = data
      expect(first).to include("occurred_at" => "2026-03-01T09:00:00.000Z",
                               "recorded_at" => received.reload.created_at.utc.iso8601(3))
      expect(first["topic"]).to eq(
        "id" => topic.id, "slug" => "add-feature", "title" => "Add a feature",
        "url" => "http://www.example.com/api/v1/topics/#{topic.id}", "html_url" => "http://www.example.com/topics/#{topic.id}"
      )
      expect(first["author"]).to include("id" => bob.person_id, "name" => "Bob B", "email" => "bob@example.org")
      expect(first["author"].keys).to match_array(%w[id name email url html_url])
      expect(first["message"].keys).to match_array(message_keys)
      expect(first["message"]).to include("id" => received.message_id, "topic_id" => topic.id, "number" => 1, "depth" => 0,
                                          "rfc_message_id" => "root@example.org", "body" => nil, "me" => nil,
                                          "is_patch_submission" => false)

      expect(second["occurred_at"]).to eq("2026-03-01T10:00:00.000Z")
      expect(second["author"]).to include("email" => "alice.a@example.org")
      expect(second["patchset"].keys).to match_array(patchset_keys)
      expect(second["patchset"]).to include("message_id" => posted.message_id, "number" => 2)
      expect(second["patchset"]["files"].map { |file| file["file_name"] }).to eq([ "v1-0001-feature.patch" ])
      expect(second["patchset"]["branch"]).to include("id" => created.patch_branch_id, "ci_status" => "success")

      expect(third["occurred_at"]).to eq("2026-03-01T10:01:00.000Z")
      expect(third["branch"].keys).to match_array(branch_keys)
      expect(third["branch"]).to include("id" => created.patch_branch_id, "message_id" => posted.message_id,
                                         "state" => "applies", "behind" => { "days" => 3, "commits" => nil })
      expect(third["branch"]["latest_run"]).to include("id" => completed.patch_ci_run_id)

      expect(fourth["occurred_at"]).to eq("2026-03-01T11:00:00.000Z")
      expect(fourth["ci_run"].keys).to match_array(run_keys)
      expect(fourth["ci_run"]).to include("id" => completed.patch_ci_run_id, "status" => "success",
                                          "first_run" => true, "previous_status" => nil)
      expect(fourth["ci_run"]["branch"]).to eq(second["patchset"]["branch"])
      expect(fourth["ci_run"]["branch"].keys).to match_array(%w[id branch_name status ci_status pushed_at url])
      expect(response.body).not_to include("secret")
    end

    it "pages with next_cursor, and gives later events from the cursor of an empty page" do
      events = Array.new(5) { message_event(topic: topic) }

      get "/api/v1/events", params: { since: "7d", limit: 2 }
      expect(ids).to eq(events.first(2).map(&:id))
      expect(body["has_more"]).to be(true)

      get "/api/v1/events", params: { since: body["next_cursor"], limit: 2 }
      expect(ids).to eq(events[2, 2].map(&:id))

      get "/api/v1/events", params: { since: body["next_cursor"], limit: 2 }
      expect(ids).to eq([ events.last.id ])
      expect(body["has_more"]).to be(false)

      get "/api/v1/events", params: { since: body["next_cursor"] }
      expect(ids).to eq([])
      expect(body["has_more"]).to be(false)
      empty = body["next_cursor"]
      expect(empty).to be_a(String)

      late = message_event(topic: topic, created_at: 5.years.ago)
      young = message_event(topic: topic, age: 1.second)
      get "/api/v1/events", params: { since: empty }
      expect(ids).to eq([ late.id ])

      aged(young, 6.seconds)
      get "/api/v1/events", params: { since: body["next_cursor"], types: "message.received" }
      expect(ids).to eq([ young.id ])
    end

    it "takes a timestamp, and names the thread the message is in now" do
      message_event(topic: topic, at: 3.hours.ago)
      moved = message_event(topic: topic, at: 1.hour.ago)
      target = create(:topic, title: "The other one")
      topic.update_columns(merged_into_topic_id: target.id)
      Message.where(topic_id: topic.id).update_all(topic_id: target.id)

      get "/api/v1/events", params: { since: 2.hours.ago.utc.iso8601 }
      expect(ids).to eq([ moved.id ])
      expect(data.first["topic"]).to include("id" => target.id, "title" => "The other one")
      expect(data.first["message"]["topic_id"]).to eq(target.id)

      get "/api/v1/events", params: { since: 2.hours.ago.utc.iso8601, topic: topic.id }
      expect(ids).to eq([ moved.id ])
    end

    it "filters by types, topic, author and list" do
      hackers = create(:mailing_list, identifier: "pgsql-hackers")
      other = create(:topic, creator_alias: bob)
      create(:topic_mailing_list, topic: other, mailing_list: hackers)
      received = message_event(topic: topic, sender: alice)
      posted, created, completed = patch_events(in_topic: other, sender: bob)

      get "/api/v1/events", params: { types: "branch.created,ci.completed" }
      expect(ids).to eq([ created.id, completed.id ])
      get "/api/v1/events", params: { topic: topic.id }
      expect(ids).to eq([ received.id ])
      get "/api/v1/events", params: { author: "bob@example.org", types: "patchset.posted" }
      expect(ids).to eq([ posted.id ])
      get "/api/v1/events", params: { author: "nobody@example.org" }
      expect(ids).to eq([])
      expect(body["next_cursor"]).to eq(Api::EventFeed.encode(completed.id))
      get "/api/v1/events", params: { list: "pgsql-hackers" }
      expect(ids).to eq([ posted.id, created.id, completed.id ])
    end

    it "leaves out CI runs that repeat the verdict of the run before them, unless all are asked for" do
      posted, created, first = patch_events
      repeat = ci_event(created.patch_branch, status: "success")
      broken = ci_event(created.patch_branch, status: "tests_failed")
      received = message_event(topic: topic)
      changed = [ posted.id, created.id, first.id, broken.id, received.id ]

      get "/api/v1/events"
      expect(ids).to eq(changed)
      expect(data[3]["ci_run"]).to include("status" => "tests_failed", "first_run" => false, "previous_status" => "success")
      expect(body["next_cursor"]).to eq(Api::EventFeed.encode(received.id))

      get "/api/v1/events", params: { ci_runs: "changed" }
      expect(ids).to eq(changed)

      get "/api/v1/events", params: { ci_runs: "all" }
      expect(ids).to eq(changed.dup.insert(3, repeat.id))
      expect(data[3]["ci_run"]).to include("status" => "success", "first_run" => false, "previous_status" => "success")

      get "/api/v1/events", params: { types: "ci.completed" }
      expect(ids).to eq([ first.id, broken.id ])
      get "/api/v1/events", params: { types: "ci.completed", ci_runs: "all", since: Api::EventFeed.encode(first.id) }
      expect(ids).to eq([ repeat.id, broken.id ])
    end

    it "leaves out hidden threads, lineage-only branches and what is gone" do
      hidden_list = create(:mailing_list, identifier: "pgsql-hidden", hidden_by_default: true)
      hidden = create(:topic, hidden_by_default: true)
      create(:topic_mailing_list, topic: hidden, mailing_list: hidden_list)
      quiet = message_event(topic: hidden)
      shown = message_event(topic: topic)
      internal = branch_event(topic: topic)
      internal.patch_branch.update_columns(lineage_only: true)
      gone = branch_event(topic: topic)
      orphan = FeedEvent.create!(event_type: "message.received", occurred_at: start, created_at: 1.minute.ago)
      gone.patch_branch.destroy!

      get "/api/v1/events"
      expect(ids).to eq([ shown.id ])
      expect(body["next_cursor"]).to eq(Api::EventFeed.encode(orphan.id))
      expect(FeedEvent.exists?(gone.id)).to be(false)

      get "/api/v1/events", params: { list: "pgsql-hidden" }
      expect(ids).to eq([ quiet.id ])
    end

    it "answers 400 for values it cannot use" do
      message_event(topic: topic)
      {
        { since: "yesterday" } => "invalid_parameter",
        { since: "91d" } => "invalid_parameter",
        { since: "2026-11-12 10:00:00" } => "invalid_parameter",
        { since: "x" * 600 } => "invalid_parameter",
        { types: "message" } => "invalid_parameter",
        { topic: "add-feature" } => "invalid_parameter",
        { list: "pgsql-nope" } => "invalid_parameter",
        { author: "a" * 255 } => "invalid_parameter",
        { starred: "false" } => "invalid_parameter",
        { participating: "1" } => "invalid_parameter",
        { ci_runs: "none" } => "invalid_parameter",
        { ci_runs: "" } => "invalid_parameter",
        { cursor: "abc" } => "invalid_parameter",
        { since: "" } => "invalid_parameter",
        { limit: "0" } => "invalid_limit"
      }.each do |params, code|
        get "/api/v1/events", params: params
        expect(response).to have_http_status(:bad_request), params.inspect
        expect(error_code).to eq(code), params.inspect
      end

      get "/api/v1/events?types[]=message.received"
      expect(error_code).to eq("invalid_parameter")
    end

    it "does not take the cursor of a list, and no list takes its cursor" do
      3.times { message_event(topic: topic) }
      get "/api/v1/topics/#{topic.id}/messages", params: { limit: 1 }
      list_cursor = body["next_cursor"]
      expect(list_cursor).to be_present

      get "/api/v1/events", params: { since: list_cursor }
      expect(response).to have_http_status(:bad_request)
      expect(error_code).to eq("invalid_parameter")

      get "/api/v1/events", params: { limit: 1 }
      get "/api/v1/topics/#{topic.id}/messages", params: { limit: 1, cursor: body["next_cursor"] }
      expect(error_code).to eq("invalid_cursor")
    end

    it "answers 410 for a position the feed does not keep any more" do
      gone = message_event(topic: topic)
      message_event(topic: topic)
      kept = message_event(topic: topic)
      FeedEvent.where("id < ?", kept.id).delete_all

      get "/api/v1/events", params: { since: Api::EventFeed.encode(gone.id) }
      expect(response).to have_http_status(:gone)
      expect(error_code).to eq("cursor_expired")
      expect(response.headers["RateLimit-Limit"]).to be_present

      get "/api/v1/events", params: { since: 100.days.ago.utc.iso8601 }
      expect(response).to have_http_status(:gone)

      get "/api/v1/events", params: { since: "90d" }
      expect(ids).to eq([ kept.id ])
    end

    it "answers 410 for a position the pruning removed and goes on from a kept one" do
      gone = message_event(topic: topic, at: 92.days.ago)
      message_event(topic: topic, at: 91.days.ago)
      kept = message_event(topic: topic, at: 89.days.ago)
      last = message_event(topic: topic)
      PruneFeedEventsJob.new.perform

      get "/api/v1/events", params: { since: Api::EventFeed.encode(gone.id) }
      expect(response).to have_http_status(:gone)
      expect(error_code).to eq("cursor_expired")

      get "/api/v1/events", params: { since: Api::EventFeed.encode(kept.id - 1) }
      expect(ids).to eq([ kept.id, last.id ])

      get "/api/v1/events", params: { since: Api::EventFeed.encode(kept.id) }
      expect(ids).to eq([ last.id ])
    end

    it "serves backfilled history by time" do
      now = Time.current.change(usec: 0)
      create(:message, topic: topic, sender: bob, created_at: now - 30.days)
      recent = create(:message, topic: topic, sender: alice, created_at: now - 3.days)
      recent.update_columns(is_patch_submission: true)
      row = create(:patch_branch, topic: topic, message: recent, attempted_at: now - 1.day)
      row.update_columns(created_at: now - 3.days + 1.minute)
      run = create(:patch_ci_run, patch_branch: row, status: "tests_failed", completed_at: now - 3.days + 1.hour)
      FeedEvent.delete_all
      FeedEvents::Backfill.new(now: now).call

      get "/api/v1/events", params: { since: "7d" }

      expect(data.map { |event| event["type"] }).to eq(%w[message.received patchset.posted branch.created ci.completed])
      expect(data.map { |event| event["occurred_at"] }).to eq(data.map { |event| event["recorded_at"] })
      expect(data.first).to include("occurred_at" => (now - 3.days).utc.iso8601(3))
      expect(data.first["author"]).to include("email" => "alice.a@example.org")
      expect(data.last["ci_run"]).to include("id" => run.id, "status" => "tests_failed")

      get "/api/v1/events", params: { since: "90d" }
      expect(data.size).to eq(5)
      expect(data.first["author"]).to include("email" => "bob@example.org")
    end

    it "is not 410 on an empty table" do
      get "/api/v1/events", params: { since: Api::EventFeed.encode(12) }

      expect(response).to have_http_status(:ok)
      expect(body).to eq("data" => [], "next_cursor" => Api::EventFeed.encode(12), "has_more" => false)
    end

    context "with the per-user filters" do
      let(:user) { create(:user, person: alice.person) }
      let(:stranger) { create(:user) }
      let(:other) { create(:topic, creator_alias: bob) }
      let!(:mine) { message_event(topic: topic, sender: alice) }
      let!(:theirs) { message_event(topic: other, sender: bob) }

      before do
        create(:topic_star, user: user, topic: other)
        create(:topic_star, user: stranger, topic: topic)
      end

      it "needs a token" do
        [ { starred: "true" }, { participating: "true" }, { starred: "true", participating: "true" } ].each do |params|
          get "/api/v1/events", params: params
          expect(response).to have_http_status(:unauthorized), params.inspect
          expect(error_code).to eq("token_required")
          expect(response.headers["WWW-Authenticate"]).to eq("Bearer")
        end
      end

      it "uses the stars and the threads of the token owner only" do
        get "/api/v1/events", params: { starred: "true" }, headers: bearer(user)
        expect(ids).to eq([ theirs.id ])
        get "/api/v1/events", params: { participating: "true" }, headers: bearer(user)
        expect(ids).to eq([ mine.id ])
        get "/api/v1/events", params: { starred: "true", participating: "true" }, headers: bearer(user)
        expect(ids).to eq([])

        get "/api/v1/events", params: { starred: "true" }, headers: bearer(stranger)
        expect(ids).to eq([ mine.id ])
        get "/api/v1/events", params: { participating: "true" }, headers: bearer(stranger)
        expect(ids).to eq([])
      end
    end

    context "with a token" do
      let(:user) { create(:user) }
      let(:featured) { create(:user).tap { |owner| create(:user_feature, user: owner, feature: "patchset_lineage") } }

      def without_me(value)
        case value
        when Hash then value.except("me").transform_values { |child| without_me(child) }
        when Array then value.map { |child| without_me(child) }
        else value
        end
      end

      it "adds the owner's read state to messages, and nothing else" do
        received = message_event(topic: topic)
        patch_events
        MessageReadRange.add_range(user: user, topic: topic, start_id: received.message_id, end_id: received.message_id)

        get "/api/v1/events"
        anonymous = body
        expect(anonymous["data"].first["message"]["me"]).to be_nil

        get "/api/v1/events", headers: bearer(user)
        expect(data.first["message"]["me"]).to eq("read" => true)
        expect(without_me(body)).to eq(without_me(anonymous))
      end

      it "gives the lineage step of a patchset only with the feature" do
        posted, = patch_events
        run = create(:patchset_run, topic: topic)
        create(:patchset_lineage, patchset_run: run, topic: topic, message: posted.message, reason: "same hunks")

        get "/api/v1/events", headers: bearer(featured)
        expect(data.first["patchset"]["lineage"]).to include("reason" => "same hunks")

        get "/api/v1/events", headers: bearer(user)
        with_token = response.body
        get "/api/v1/events"
        [ with_token, response.body ].each do |text|
          expect(text).not_to include("lineage", "same hunks")
        end
        expect(data.first["patchset"].keys).to match_array(patchset_keys)
      end
    end

    it "runs the same queries for one event of each type and for three, never reads a payload and does not write" do
      create(:patch_ci_repo_state)
      mixed = lambda do |at|
        thread = create(:topic, creator_alias: bob)
        sender = create(:alias, :with_sent_messages)
        message_event(topic: thread, sender: sender, created_at: at)
        _, created, = patch_events(in_topic: thread, sender: sender, at: at + 1.hour)
        # not the run of the event: the same rows asked for twice are read once, or twice in another order
        latest = create(:patch_ci_run, patch_branch: created.patch_branch, status: "running")
        created.patch_branch.update_columns(latest_ci_run_id: latest.id)
      end
      mixed.call(start)
      get "/api/v1/events"
      one = captured_queries { get "/api/v1/events" }
      expect(data.size).to eq(4)

      2.times { |i| mixed.call(start + (i + 1).days) }
      three = captured_queries { get "/api/v1/events" }

      expect(data.size).to eq(12)
      expect(data.map { |row| row["type"] }.tally.values).to eq([ 3, 3, 3, 3 ])
      expect(three.size).to eq(one.size)
      expect(three.grep(/\A\s*(INSERT|UPDATE|DELETE)/i)).to be_empty
      expect(three.grep(/FROM "patch_ci_runs"/).grep(/payload|"patch_ci_runs"\.\*/)).to be_empty
      expect(three.grep(/FROM "messages"/).grep(/"messages"\."body"|"messages"\.\*/)).to be_empty
      expect(response.body).not_to include("secret")
    end

    it "is cheap when nothing is new" do
      message_event(topic: topic)
      get "/api/v1/events"
      cursor = body["next_cursor"]

      queries = captured_queries { get "/api/v1/events", params: { since: cursor } }

      expect(body).to eq("data" => [], "next_cursor" => cursor, "has_more" => false)
      expect(queries.grep_v(/\ASET LOCAL/).size).to eq(1)
      expect(queries.size).to eq(2)
    end
  end
end
