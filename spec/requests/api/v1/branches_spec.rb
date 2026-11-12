require "rails_helper"

RSpec.describe "API v1 branches", type: :request do
  let(:alice) { create(:alias, :with_sent_messages, name: "Alice A", email: "alice.a@example.org") }
  let(:bob) { create(:alias, :with_sent_messages, name: "Bob B", email: "bob@example.org") }
  let(:topic) { create(:topic, creator_alias: alice, title: "Add a feature", slug: "add-feature") }
  let(:start) { Time.zone.parse("2026-03-01 10:00:00") }

  let(:branch_keys) do
    %w[id url html_url branch_name topic message_id status failure_stage failure_reason conflict_files
       state state_reason superseded base_sha base_source base_committed_at on_master pg_major behind attempted_at pushed_at
       pushed_head_sha github_url git_url last_master_apply_at master_apply_sha master_apply_error master_conflict_files
       ci_status ci_skip_reason latest_run created_at updated_at]
  end
  let(:run_keys) do
    %w[id github_run_id run_attempt status head_sha pg_major queued_at started_at completed_at build_seconds
       test_seconds tests_total failed_tests image_ref image_pull_ref image_digest created_at github_url]
  end
  let(:github) { "https://github.com/#{PatchCi::Config::GITHUB_REPO}" }

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

  def branch(at: start, in_topic: topic, sender: alice, **attrs)
    message = create(:message, topic: in_topic, sender: sender, created_at: at)
    row = create(:patch_branch, topic: in_topic, message: message, pushed_at: at, base_committed_at: at, **attrs)
    row.update_columns(updated_at: at)
    row
  end

  def run_for(row, status: "success", **attrs)
    run = create(:patch_ci_run, patch_branch: row, status: status, payload: { "secret" => "x" * 50 }, **attrs)
    row.update_columns(latest_ci_run_id: run.id, ci_status: status)
    run
  end

  describe "GET /branches" do
    it "lists current branches by update time with the documented row, without a token" do
      create(:patch_ci_repo_state, master_committed_at: start + 3.days, master_commit_height: 1000)
      older = branch(branch_name: "t#{topic.id}_1")
      row = branch(at: start + 1.hour, branch_name: "t#{topic.id}_4", base_sha: "a" * 40, base_source: "master",
                   base_commit_height: 990, pg_major: 19, pushed_head_sha: "b" * 40,
                   last_master_apply_at: start + 2.hours, master_apply_sha: "c" * 40,
                   master_conflict_files: [ "src/a.c" ])
      run = run_for(row, status: "tests_failed", run_attempt: 2, head_sha: "b" * 40, pg_major: 19,
                         queued_at: start + 1.hour, started_at: start + 2.hours, completed_at: start + 3.hours,
                         build_seconds: 120, test_seconds: 300, tests_total: 250, failed_tests: [ "regress/foo" ],
                         image_ref: "ghcr.io/x/pg:t1", image_digest: "sha256:abc", created_at: start + 90.minutes)
      row.update_columns(created_at: start - 1.day, updated_at: start + 1.hour, master_apply_error: "conflict")

      get "/api/v1/branches"

      expect(response).to have_http_status(:ok)
      expect(response.headers["RateLimit-Limit"]).to be_present
      expect(body.keys).to match_array(%w[data next_cursor])
      expect(body["next_cursor"]).to be_nil
      expect(ids).to eq([ row.id, older.id ])

      json = data.first
      expect(json.keys).to match_array(branch_keys)
      expect(json).to include(
        "id" => row.id, "branch_name" => "t#{topic.id}_4", "message_id" => row.message_id,
        "status" => "applied", "failure_stage" => nil, "failure_reason" => nil, "conflict_files" => [],
        "state" => "needs_rebase", "state_reason" => nil, "superseded" => false, "base_sha" => "a" * 40, "base_source" => "master",
        "base_committed_at" => "2026-03-01T11:00:00.000Z", "on_master" => true, "pg_major" => 19,
        "behind" => { "days" => 2, "commits" => 10 }, "pushed_at" => "2026-03-01T11:00:00.000Z",
        "pushed_head_sha" => "b" * 40, "github_url" => "#{github}/tree/t#{topic.id}_4",
        "last_master_apply_at" => "2026-03-01T12:00:00.000Z", "master_apply_sha" => "c" * 40,
        "master_apply_error" => "conflict", "master_conflict_files" => [ "src/a.c" ],
        "ci_status" => "tests_failed", "ci_skip_reason" => nil, "created_at" => "2026-02-28T10:00:00.000Z",
        "updated_at" => "2026-03-01T11:00:00.000Z"
      )
      expect(json["url"]).to end_with("/api/v1/branches/#{row.id}")
      expect(json["html_url"]).to end_with("/ci/topics/#{topic.id}")
      expect(json["html_url"]).not_to include("/api/")
      expect(json["topic"].keys).to match_array(%w[id slug title url html_url])
      expect(json["topic"]).to include("id" => topic.id, "slug" => "add-feature", "title" => "Add a feature")
      expect(json["topic"]["url"]).to end_with("/api/v1/topics/#{topic.id}")

      latest = json["latest_run"]
      expect(latest.keys).to match_array(run_keys)
      expect(latest).to include(
        "id" => run.id, "github_run_id" => run.github_run_id, "run_attempt" => 2, "status" => "tests_failed",
        "head_sha" => "b" * 40, "pg_major" => 19, "queued_at" => "2026-03-01T11:00:00.000Z",
        "started_at" => "2026-03-01T12:00:00.000Z", "completed_at" => "2026-03-01T13:00:00.000Z",
        "build_seconds" => 120, "test_seconds" => 300, "tests_total" => 250, "failed_tests" => [ "regress/foo" ],
        "image_ref" => "ghcr.io/x/pg:t1", "image_pull_ref" => "ghcr.io/x/pg@sha256:abc",
        "image_digest" => "sha256:abc", "created_at" => "2026-03-01T11:30:00.000Z",
        "github_url" => "#{github}/actions/runs/#{run.github_run_id}/attempts/2"
      )
      expect(data.last).to include("latest_run" => nil, "ci_status" => nil, "state" => "applies")
      expect(data.last["behind"]).to eq("days" => 3, "commits" => nil)
    end

    it "gives the status of the push and the last accepted run as stored when they differ" do
      row = branch(pushed_head_sha: "b" * 40)
      run = run_for(row, status: "tests_failed", head_sha: "a" * 40)
      row.update_columns(ci_status: "pushed_awaiting_ci")

      get "/api/v1/branches"

      expect(data.first).to include("ci_status" => "pushed_awaiting_ci", "pushed_head_sha" => "b" * 40,
                                    "state" => "awaiting_ci")
      expect(data.first["latest_run"]).to include("id" => run.id, "status" => "tests_failed", "head_sha" => "a" * 40)
    end

    it "says why a branch will not be retried, and nothing for the other states" do
      create(:patch_ci_repo_state, master_committed_at: start + 1.day)
      committed = create(:topic, creator_alias: alice, last_commit_at: start + 2.hours)
      merged = create(:topic, creator_alias: alice, merged_into_topic_id: topic.id)
      normal = branch
      landed = branch(at: start + 1.hour, in_topic: committed)
      moved = branch(at: start + 2.hours, in_topic: merged)
      aged = branch(at: start + 3.hours, base_committed_at: start - 90.days)
      skipped = branch(at: start + 4.hours, ci_status: "ci_none", ci_skip_reason: "patchset touches .github/")
      unexplained = branch(at: start + 5.hours, ci_status: "ci_none")
      failed = branch(at: start + 6.hours, status: "failed", on_master: false, failure_stage: "apply",
                      base_committed_at: start - 90.days)

      get "/api/v1/branches"

      expect(data.map { |row| [ row["id"], row["state"], row["state_reason"] ] }).to eq(
        [ [ failed.id, "never_applied", nil ], [ unexplained.id, "wont_retry", "ci_none" ],
          [ skipped.id, "wont_retry", "patchset touches .github/" ], [ aged.id, "wont_retry", "base too old" ],
          [ moved.id, "wont_retry", "merged thread" ], [ landed.id, "wont_retry", "committed" ],
          [ normal.id, "applies", nil ] ]
      )

      get "/api/v1/branches/#{landed.id}"
      expect(body).to include("state" => "wont_retry", "state_reason" => "committed")

      get "/api/v1/branches/#{normal.id}"
      expect(body).to include("state" => "applies", "state_reason" => nil)
    end

    it "gives nulls for a branch that was never pushed and has an odd name, and clamps behind at zero" do
      create(:patch_ci_repo_state, master_committed_at: start - 1.day, master_commit_height: 10)
      branch(branch_name: "oddname", pushed_at: nil, base_commit_height: 20)
      branch(at: start + 1.hour, base_committed_at: nil)

      get "/api/v1/branches"

      expect(data.last).to include("branch_name" => "oddname", "github_url" => nil, "pushed_at" => nil,
                                   "behind" => { "days" => 0, "commits" => 0 })
      expect(data.first["behind"]).to be_nil
    end

    it "cuts long failure text" do
      row = branch(status: "failed", on_master: false, failure_stage: "apply", failure_reason: "x" * 5000,
                   conflict_files: [ "a.c" ])
      row.update_columns(master_apply_error: "y" * 5000)

      get "/api/v1/branches"

      expect(data.first).to include("status" => "failed", "failure_stage" => "apply", "conflict_files" => [ "a.c" ],
                                    "failure_reason" => "x" * 2000, "master_apply_error" => "y" * 2000,
                                    "state" => "never_applied")
    end

    it "hides superseded rows unless current=false, and never shows lineage-only ones" do
      current = branch(at: start + 2.hours)
      old = branch(at: start + 1.hour, superseded_by_id: current.id)
      branch(at: start + 3.hours, lineage_only: true, branch_name: "hidden_9")
      branch(at: start, lineage_only: true, superseded_by_id: current.id, branch_name: "hidden_8")

      get "/api/v1/branches"
      expect(ids).to eq([ current.id ])
      expect(data.first["superseded"]).to be(false)

      get "/api/v1/branches", params: { current: "true" }
      expect(ids).to eq([ current.id ])

      get "/api/v1/branches", params: { current: "false" }
      expect(ids).to eq([ current.id, old.id ])
      expect(data.map { |row| row["superseded"] }).to eq([ false, true ])
      expect(response.body).not_to include("hidden_")
    end

    it "filters by topic, author, pg_major and ci_status" do
      other = create(:topic, creator_alias: bob, title: "Other")
      mine = branch(pg_major: 18)
      theirs = branch(at: start + 1.hour, in_topic: other, sender: bob, pg_major: 19)
      run_for(theirs, status: "tests_failed")

      get "/api/v1/branches", params: { topic: other.id }
      expect(ids).to eq([ theirs.id ])

      get "/api/v1/branches", params: { author: "ALICE.A@example.org" }
      expect(ids).to eq([ mine.id ])

      get "/api/v1/branches", params: { author: "nobody@example.org" }
      expect(response).to have_http_status(:ok)
      expect(body).to eq("data" => [], "next_cursor" => nil)

      get "/api/v1/branches", params: { pg_major: 19 }
      expect(ids).to eq([ theirs.id ])

      get "/api/v1/branches", params: { ci_status: "tests_failed" }
      expect(ids).to eq([ theirs.id ])

      get "/api/v1/branches", params: { ci_status: "none" }
      expect(ids).to eq([ mine.id ])

      get "/api/v1/branches", params: { ci_status: "success", topic: other.id }
      expect(ids).to eq([])
    end

    it "finds the author by any address of the person, also together with a state" do
      create(:patch_ci_repo_state, master_committed_at: start + 1.day)
      create(:alias, person: alice.person, name: "Alice Other", email: "alice.other@example.org")
      applies = branch
      rebase = branch(at: start + 1.hour, on_master: false)
      branch(at: start + 2.hours, sender: bob, on_master: false)

      get "/api/v1/branches", params: { author: "alice.other@example.org" }
      expect(ids).to eq([ rebase.id, applies.id ])

      get "/api/v1/branches", params: { author: "alice.other@example.org", state: "needs_rebase" }
      expect(ids).to eq([ rebase.id ])

      get "/api/v1/branches", params: { author: "alice.a@example.org", state: "wont_retry" }
      expect(ids).to eq([])
    end

    it "returns the rows of a merged topic under its own id" do
      merged = create(:topic, creator_alias: alice, merged_into_topic_id: topic.id)
      branch
      row = branch(in_topic: merged)

      get "/api/v1/branches", params: { topic: merged.id }

      expect(response).to have_http_status(:ok)
      expect(ids).to eq([ row.id ])
      expect(data.first["state"]).to eq("wont_retry")
    end

    it "filters by state and names rows as /ci/branches does" do
      state = create(:patch_ci_repo_state, master_committed_at: start + 1.day)
      applies = branch
      rebase = branch(at: start + 1.hour, on_master: false)
      failed = branch(at: start + 2.hours, status: "failed", on_master: false, failure_stage: "apply")
      waiting = branch(at: start + 3.hours, pushed_at: nil)
      retired = branch(at: start + 4.hours, base_committed_at: start - 90.days)

      get "/api/v1/branches"
      expect(data.map { |row| [ row["id"], row["state"] ] }).to eq(
        [ [ retired.id, "wont_retry" ], [ waiting.id, "awaiting_ci" ], [ failed.id, "never_applied" ],
          [ rebase.id, "needs_rebase" ], [ applies.id, "applies" ] ]
      )
      site = PatchCi::BranchQuery.new(params: {}, repo_state: state).rows.to_h { |row| [ row.id, row.health_bucket ] }
      expect(data.to_h { |row| [ row["id"], row["state"] ] }).to eq(site)

      { "applies" => applies, "needs_rebase" => rebase, "never_applied" => failed, "awaiting_ci" => waiting,
        "wont_retry" => retired }.each do |name, row|
        get "/api/v1/branches", params: { state: name }
        expect(ids).to eq([ row.id ])
      end
    end

    it "rejects values it cannot use" do
      branch

      [ { topic: "add-feature" }, { topic: "-1" }, { topic: "9" * 30 }, { state: "broken" }, { ci_status: "green" },
        { pg_major: "x" }, { pg_major: "9" * 12 }, { current: "yes" }, { current: "" }, { author: [ "a" ] },
        { author: "" }, { author: " " }, { author: "#{'a' * 243}@example.org" }, { state: "a\0b" } ].each do |params|
        get "/api/v1/branches", params: params
        expect(response).to have_http_status(:bad_request), params.inspect
        expect(error_code).to eq("invalid_parameter")
      end

      get "/api/v1/branches", params: { author: "#{'a' * 242}@example.org" }
      expect(response).to have_http_status(:ok)

      get "/api/v1/branches", params: { limit: 0 }
      expect(error_code).to eq("invalid_limit")

      get "/api/v1/branches", params: { cursor: "nope" }
      expect(error_code).to eq("invalid_cursor")
    end

    it "takes a cursor only with the filters it came from" do
      create(:patch_ci_repo_state, master_committed_at: start)
      3.times { |i| branch(at: start + i.hours) }
      get "/api/v1/branches", params: { limit: 1, state: "applies" }
      cursor = body["next_cursor"]
      expect(cursor).to be_present

      [ { state: "needs_rebase" }, {}, { state: "applies", current: "false" }, { state: "applies", topic: topic.id } ].each do |params|
        get "/api/v1/branches", params: params.merge(cursor: cursor)
        expect(response).to have_http_status(:bad_request), params.inspect
        expect(error_code).to eq("invalid_cursor")
      end

      get "/api/v1/branches", params: { limit: 5, state: "applies", cursor: cursor }
      expect(response).to have_http_status(:ok)
      expect(ids.size).to eq(2)
    end

    it "rejects a parameter it does not know" do
      get "/api/v1/branches", params: { status: "applied" }
      expect(response).to have_http_status(:bad_request)
      expect(error_code).to eq("invalid_parameter")
      expect(body.dig("error", "message")).to eq("unknown parameter: status")

      get "/api/v1/branches/#{branch.id}", params: { current: "false" }
      expect(response).to have_http_status(:bad_request)
      expect(error_code).to eq("invalid_parameter")

      get "/api/v1/branches/#{branch.id}/ci_runs", params: { state: "applies" }
      expect(response).to have_http_status(:bad_request)
      expect(error_code).to eq("invalid_parameter")
    end

    it "gives the repository to fetch a pushed branch from, and none before the push" do
      pushed = branch(branch_name: "t#{topic.id}_1")
      waiting = branch(at: start + 1.hour, branch_name: "t#{topic.id}_2", pushed_at: nil)

      get "/api/v1/branches/#{pushed.id}"
      expect(body["git_url"]).to eq("https://github.com/#{PatchCi::Config::GITHUB_REPO}.git")
      expect(body["git_url"]).to eq(ApplicationController.helpers.ci_github_clone_url)

      get "/api/v1/branches/#{waiting.id}"
      expect(body).to include("git_url" => nil, "github_url" => nil, "pushed_at" => nil)
    end

    it "pages through ties, with a filter" do
      create(:patch_ci_repo_state, master_committed_at: start)
      tied = Array.new(3) { branch(at: start + 1.hour) }
      oldest = branch
      branch(at: start + 2.hours, on_master: false)

      seen = []
      cursor = nil
      2.times do
        get "/api/v1/branches", params: { limit: 2, state: "applies", cursor: cursor }.compact
        expect(response).to have_http_status(:ok)
        seen.concat(ids)
        cursor = body["next_cursor"]
      end

      expect(cursor).to be_nil
      expect(seen).to eq([ tied[2].id, tied[1].id, tied[0].id, oldest.id ])
    end

    it "answers without a repo state as the site does" do
      fresh = branch
      run_for(fresh)
      old = branch(at: start - 1.day, base_committed_at: Time.zone.parse("2015-01-01"))

      get "/api/v1/branches"

      expect(response).to have_http_status(:ok)
      expect(data.map { |row| [ row["id"], row["state"], row["behind"] ] })
        .to eq([ [ fresh.id, "applies", nil ], [ old.id, "wont_retry", nil ] ])
      expect(data.first["latest_run"]).to include("status" => "success")
      site = PatchCi::BranchQuery.new(params: {}, repo_state: nil).rows.to_h { |row| [ row.id, row.health_bucket ] }
      expect(data.to_h { |row| [ row["id"], row["state"] ] }).to eq(site)

      get "/api/v1/branches", params: { state: "wont_retry" }
      expect(ids).to eq([ old.id ])
    end

    it "runs the same queries for one row and for three, never reads a payload and does not write" do
      create(:patch_ci_repo_state)
      decorated = lambda do |at|
        thread = create(:topic, creator_alias: bob)
        run_for(branch(at: at, in_topic: thread, sender: create(:alias, :with_sent_messages)))
      end
      decorated.call(start)
      one = captured_queries { get "/api/v1/branches" }
      expect(data.size).to eq(1)

      2.times { |i| decorated.call(start + (i + 1).hours) }
      three = captured_queries { get "/api/v1/branches" }

      expect(data.size).to eq(3)
      expect(data.map { |row| row["latest_run"] }).to all(be_present)
      expect(three.size).to eq(one.size)
      expect(three.grep(/\A\s*(INSERT|UPDATE|DELETE)/i)).to be_empty
      on_runs = three.grep(/FROM "patch_ci_runs"/)
      expect(on_runs.size).to eq(1)
      expect(on_runs.grep(/payload|"patch_ci_runs"\.\*/)).to be_empty
      expect(response.body).not_to include("secret")
    end
  end

  describe "GET /branches/{id}" do
    it "shows one branch with its latest run" do
      create(:patch_ci_repo_state, master_committed_at: start + 1.day)
      row = branch(branch_name: "t#{topic.id}_2")
      run = run_for(row)

      queries = captured_queries { get "/api/v1/branches/#{row.id}" }

      expect(response).to have_http_status(:ok)
      expect(body.keys).to match_array(branch_keys)
      expect(body).to include("id" => row.id, "state" => "applies", "ci_status" => "success",
                              "behind" => { "days" => 1, "commits" => nil })
      expect(body["latest_run"].keys).to match_array(run_keys)
      expect(body["latest_run"]).to include("id" => run.id,
                                            "github_url" => "#{github}/actions/runs/#{run.github_run_id}")
      expect(queries.grep(/\A\s*(INSERT|UPDATE|DELETE)/i)).to be_empty
      expect(queries.grep(/FROM "patch_ci_runs"/).grep(/payload|"patch_ci_runs"\.\*/)).to be_empty
      expect(response.body).not_to include("secret")
    end

    it "shows a superseded branch, without a repo state too" do
      current = branch(at: start + 1.hour)
      row = branch(superseded_by_id: current.id)

      get "/api/v1/branches/#{row.id}"

      expect(response).to have_http_status(:ok)
      expect(body).to include("id" => row.id, "superseded" => true, "behind" => nil, "latest_run" => nil)
    end

    it "answers an unknown or lineage-only branch with 404" do
      hidden = branch(lineage_only: true)

      [ hidden.id, hidden.id + 1000, "9" * 30 ].each do |id|
        get "/api/v1/branches/#{id}"
        expect(response).to have_http_status(:not_found), id.to_s
        expect(error_code).to eq("not_found")
      end
    end
  end

  describe "GET /branches/{id}/ci_runs" do
    it "lists the runs newest first with the documented row" do
      row = branch
      first = create(:patch_ci_run, patch_branch: row, status: "build_failed", created_at: start + 1.hour,
                                    payload: { "secret" => "x" })
      second = create(:patch_ci_run, patch_branch: row, github_run_id: first.github_run_id, run_attempt: 2,
                                     status: "success", created_at: start, conclusion: "success",
                                     image_ref: "ghcr.io/x/pg:t1", payload: { "secret" => "x" })
      expect(second.id).to be > first.id
      create(:patch_ci_run, patch_branch: branch(at: start + 1.hour))

      queries = captured_queries { get "/api/v1/branches/#{row.id}/ci_runs" }

      expect(response).to have_http_status(:ok)
      expect(body.keys).to match_array(%w[data next_cursor])
      expect(body["next_cursor"]).to be_nil
      expect(ids).to eq([ first.id, second.id ])
      expect(data.first.keys).to match_array(run_keys)
      expect(data.map { |run| run["status"] }).to eq(%w[build_failed success])
      expect(data.map { |run| run["created_at"] }).to eq(%w[2026-03-01T11:00:00.000Z 2026-03-01T10:00:00.000Z])
      expect(data.last["github_url"]).to eq("#{github}/actions/runs/#{first.github_run_id}/attempts/2")
      expect(data.last).to include("image_ref" => "ghcr.io/x/pg:t1", "image_digest" => nil, "image_pull_ref" => nil)
      expect(data.first).to include("failed_tests" => [], "tests_total" => nil, "queued_at" => nil,
                                    "image_ref" => nil, "image_pull_ref" => nil,
                                    "github_url" => "#{github}/actions/runs/#{first.github_run_id}")
      expect(queries.grep(/\A\s*(INSERT|UPDATE|DELETE)/i)).to be_empty
      on_runs = queries.grep(/FROM "patch_ci_runs"/)
      expect(on_runs).not_to be_empty
      expect(on_runs.grep(/payload|"patch_ci_runs"\.\*/)).to be_empty
      expect(response.body).not_to include("secret")
    end

    it "pages through ties and answers a branch without runs with no rows" do
      row = branch
      runs = Array.new(3) { create(:patch_ci_run, patch_branch: row, created_at: start) }

      get "/api/v1/branches/#{row.id}/ci_runs", params: { limit: 2 }
      expect(ids).to eq([ runs[2].id, runs[1].id ])

      get "/api/v1/branches/#{row.id}/ci_runs", params: { limit: 2, cursor: body["next_cursor"] }
      expect(ids).to eq([ runs[0].id ])
      expect(body["next_cursor"]).to be_nil

      get "/api/v1/branches/#{branch(at: start + 1.hour).id}/ci_runs"
      expect(body).to eq("data" => [], "next_cursor" => nil)

      get "/api/v1/branches/#{row.id}/ci_runs", params: { limit: "x" }
      expect(error_code).to eq("invalid_limit")
    end

    it "runs the same queries for one run and for three" do
      row = branch
      create(:patch_ci_run, patch_branch: row)
      one = captured_queries { get "/api/v1/branches/#{row.id}/ci_runs" }

      2.times { create(:patch_ci_run, patch_branch: row) }
      three = captured_queries { get "/api/v1/branches/#{row.id}/ci_runs" }

      expect(data.size).to eq(3)
      expect(three.size).to eq(one.size)
    end

    it "answers an unknown or lineage-only branch with 404" do
      hidden = branch(lineage_only: true)
      create(:patch_ci_run, patch_branch: hidden)

      [ hidden.id, hidden.id + 1000, "9" * 30 ].each do |id|
        get "/api/v1/branches/#{id}/ci_runs"
        expect(response).to have_http_status(:not_found), id.to_s
        expect(error_code).to eq("not_found")
      end
    end
  end
end
