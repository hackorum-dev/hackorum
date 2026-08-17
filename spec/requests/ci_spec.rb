# frozen_string_literal: true

require "rails_helper"

RSpec.describe "CI dashboard", type: :request do
  # lets an example assert a plain string lands in the right section instead of
  # anywhere on the page. Parsed, not sliced: the tab panels are divs, so there
  # is no closing tag a regex could stop at
  def section(id)
    Nokogiri::HTML(response.body).at_css("##{id}").to_html
  end

  # th texts with any sort link and direction arrow stripped, so the dashboard's
  # plain headers and the branches page's sortable ones compare equal
  def header_labels(body)
    body[/<tr><th>Result.*?<\/tr>/m].to_s.scan(/<th[^>]*>(.*?)<\/th>/m)
       .map { |(cell)| cell.gsub(/<[^>]+>/, "").delete(CiHelper::SORT_ARROWS.values.join).strip }
  end

  # header row plus the first data row of the shared table, so an example can
  # name a column instead of hoping a string lands in the right cell
  def first_table_row(body)
    rows = Nokogiri::HTML(body).at_css("table.ci-table").css("tr")
    headers = rows.first.css("th").map do |th|
      th.text.delete(CiHelper::SORT_ARROWS.values.join).strip
    end
    [ headers, rows[1].css("td") ]
  end

  # the strip's tiles are k/v/d triples in document order, so name the tile
  # rather than hoping a bare number lands in the right one
  def stat_tile(key)
    Nokogiri::HTML(response.body).css(".ci-strip .stat")
            .find { |tile| tile.at_css(".k")&.text&.strip == key }
  end

  def branch_with_run(branch_attrs = {}, run_attrs = {})
    branch = create(:patch_branch, **branch_attrs)
    run = create(:patch_ci_run, patch_branch: branch, **run_attrs)
    branch.update!(latest_ci_run: run)
    [ branch, run ]
  end

  describe "GET /ci" do
    it "renders the empty state for guests" do
      get "/ci"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("orchestrator not running")
      expect(response.body).to include("nothing running")
      expect(response.body).to include("plan is empty")
      expect(response.body).to include("no branches yet")
      expect(response.body).to include("Branch health")
    end

    it "shows the heartbeat as running while the repo state is fresh" do
      create(:patch_ci_repo_state, master_sha: "bf12ac9de" + "0" * 31, fetched_at: 10.seconds.ago)

      get "/ci"

      expect(response.body).to include("ci-up")
      expect(response.body).not_to include("orchestrator not running")
      expect(response.body).to include("bf12ac9de")
    end

    it "shows the heartbeat as down when the last cycle is stale" do
      create(:patch_ci_repo_state, fetched_at: 30.minutes.ago)

      get "/ci"

      expect(response.body).to include("orchestrator not running")
      expect(response.body).to include("ago")
    end

    it "renders every section with data" do
      create(:patch_ci_repo_state)
      topic = create(:topic, last_message_at: Time.current)
      msg = create(:message, topic: topic, created_at: 1.day.ago, is_patch_submission: true)
      running = create(:patch_branch, topic: topic, pushed_at: 1.hour.ago, ci_status: "running")
      row, = branch_with_run(
        { topic: topic, message: msg, pushed_at: 2.hours.ago, ci_status: "tests_failed",
          base_committed_at: 2.days.ago, base_commit_height: 10 },
        { status: "tests_failed", pg_major: 18, completed_at: 5.minutes.ago, tests_total: 229,
          failed_tests: [ "regress/self_contradictory" ],
          build_seconds: 185, test_seconds: 281,
          image_ref: "ghcr.io/hackorum-dev/postgres-patch:t1" }
      )

      get "/ci"

      expect(response).to have_http_status(:ok)
      expect(section("in-progress")).to include(running.branch_name)
      expect(section("in-progress")).to include("60m elapsed")
      expect(response.body).to include(topic.title)
      # section-scoped: "tests failed" also appears in the last-24h strip
      recent = section("recent")
      expect(recent).to include(row.branch_name)
      expect(recent).to include("tests failed")
      expect(recent).to include("228 / 229")
      expect(recent).to include(%(title="Failed: regress/self_contradictory"))
      expect(recent).to include("3m 05s / 4m 41s")
      expect(recent).to include("docker run")
      # last 24h summary
      expect(response.body).to include("1 runs")
      # one scroll region per section, each named for its own section
      expect(section("in-progress")).to include(%(aria-label="In progress branches"))
      expect(recent).to include(%(aria-label="Recent results"))
    end

    # the labels have to match where they land: "all branches" under a filtered
    # preset, or "full plan" over a page Planner has no say in, both lie
    it "sends the sidebar nav to the unfiltered branch table" do
      get "/ci"

      nav = Nokogiri::HTML(response.body).at_css(".layout-sidebar").to_html
      expect(nav).to match(%r{href="/ci/branches"[^>]*>All branches<})
    end

    it "renders the three lists as tabs, the first one selected" do
      get "/ci"
      doc = Nokogiri::HTML(response.body)

      tabs = doc.css(".ci-tab")
      expect(tabs.map { |tab| tab.text.strip }).to eq([ "In progress", "Up next", "Recent results" ])
      expect(tabs.map { |tab| tab["aria-selected"] }).to eq([ "true", "false", "false" ])
      # every tab points at a panel that is on the page
      panels = doc.css(".ci-tab-panel").map { |panel| panel["id"] }
      expect(tabs.map { |tab| tab["aria-controls"] }).to eq(panels)
      expect(panels).to eq([ "in-progress", "up-next", "recent" ])
      expect(doc.css(".ci-tab-panel.is-active").size).to eq(1)
    end

    # a broadcast refresh morphs the page, and the server always marks the first
    # tab active - without the controller the reader is thrown back to it
    it "wires the tabs for morph refreshes" do
      get "/ci"

      expect(response.body).to include(%(data-controller="tabs tabs-morph"))
    end

    it "sends branch health to the recent-ish preset" do
      get "/ci"

      expect(section("health")).to include(%(href="/ci/branches?base=recent%2Cstale"))
      expect(section("health")).to include(">recent branches<")
    end

    it "lists an unapplied patch version in the forecast" do
      create(:patch_ci_repo_state)
      topic = create(:topic, last_message_at: Time.current)
      create(:message, topic: topic, created_at: 30.minutes.ago, is_patch_submission: true)

      get "/ci"

      expect(response.body).to include("new version")
      expect(response.body).to include("patch posted 30 minutes ago")
      expect(response.body).to include("apply + push")
    end

    it "clamps the passed test count at zero" do
      create(:patch_ci_repo_state)
      topic = create(:topic, last_message_at: Time.current)
      branch_with_run({ topic: topic, pushed_at: 2.hours.ago, ci_status: "tests_failed" },
                      { status: "tests_failed", completed_at: 1.hour.ago,
                        tests_total: 2, failed_tests: [ "a", "b", "c" ] })

      get "/ci"

      expect(response.body).to include("0 / 2")
    end

    it "surfaces the branch skip reason on an infra error badge" do
      create(:patch_ci_repo_state)
      topic = create(:topic, last_message_at: Time.current)
      branch_with_run({ topic: topic, pushed_at: 3.days.ago, ci_status: "infra_error",
                        ci_skip_reason: "no verdict after 48h" },
                      { status: "infra_error", completed_at: 1.hour.ago })

      get "/ci"

      expect(response.body).to include("infra error")
      expect(response.body).to include("no verdict after 48h")
      # a run without an image ref offers nothing to copy
      expect(response.body).not_to include("docker run")
    end

    it "splits the awaiting CI bucket by pushed state" do
      create(:patch_ci_repo_state)
      topic = create(:topic, last_message_at: Time.current)
      create(:patch_branch, topic: topic, pushed_at: nil)
      create(:patch_branch, topic: topic, pushed_at: nil)
      other = create(:topic, last_message_at: Time.current)
      create(:patch_branch, topic: other, pushed_at: 5.minutes.ago, ci_status: "queued")

      get "/ci"

      # counts pinned, so a flipped grouped-count key cannot pass silently
      expect(response.body).to match(%r{not yet pushed</span>\s*<span>2</span>})
      expect(response.body).to match(%r{pushed, awaiting verdict</span>\s*<span>1</span>})
    end

    it "honours the in-progress list limit" do
      stub_const("PatchCi::Config::IN_PROGRESS_LIST", 1)
      create(:patch_ci_repo_state)
      topic = create(:topic, last_message_at: Time.current)
      # the list orders by updated_at. Created first (so id DESC disagrees) and
      # pushed last (so pushed_at DESC disagrees too) - either revert now fails
      # instead of passing on creation order
      newer = create(:patch_branch, topic: topic, pushed_at: 2.hours.ago, ci_status: "running",
                     updated_at: 5.minutes.ago)
      older = create(:patch_branch, topic: topic, pushed_at: 5.minutes.ago, ci_status: "running",
                     updated_at: 2.hours.ago)

      get "/ci"

      expect(response.body).to include(newer.branch_name)
      expect(response.body).not_to include(older.branch_name)
      expect(response.body).to include("1 of 2 shown")
    end

    it "honours the recent results limit" do
      stub_const("PatchCi::Config::RECENT_LIST", 1)
      create(:patch_ci_repo_state)
      topic = create(:topic, last_message_at: Time.current)
      # created first and pushed last, so neither id DESC nor pushed_at DESC
      # reproduces the expected order by accident
      newer = create(:patch_branch, topic: topic, ci_status: "build_failed", pushed_at: 3.hours.ago,
                     updated_at: 1.minute.ago)
      older = create(:patch_branch, topic: topic, ci_status: "success", pushed_at: 1.minute.ago,
                     updated_at: 3.hours.ago)

      get "/ci"

      expect(response.body).to include(newer.branch_name)
      expect(response.body).not_to include(older.branch_name)
    end

    it "does not load run payloads into the dashboard" do
      create(:patch_ci_repo_state)
      branch_with_run({ topic: create(:topic, last_message_at: Time.current),
                        ci_status: "success", pushed_at: 1.hour.ago },
                      { status: "success", completed_at: 1.hour.ago,
                        payload: { secret: "x" * 100 } })

      queries = []
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        queries << payload[:sql]
      end
      get "/ci"
      ActiveSupport::Notifications.unsubscribe(sub)

      run_queries = queries.select { |q| q.include?("patch_ci_runs") && q.start_with?("SELECT") }
      expect(run_queries).to be_present
      expect(run_queries.none? { |q| q.include?("payload") }).to be(true)
      # a revert to SELECT * would drop the word "payload" and pass vacuously
      expect(run_queries.none? { |q| q.include?(%("patch_ci_runs".*)) }).to be(true)
    end

    it "shows elapsed time instead of durations for an in-flight row" do
      create(:patch_ci_repo_state)
      row = create(:patch_branch, ci_status: "running", pushed_at: 14.minutes.ago)

      get "/ci"

      expect(response.body).to include(row.branch_name)
      expect(response.body).to include("14m elapsed")
    end

    # one partial feeds both, but only the branches page turns four headers into
    # sort links - so compare the column labels rather than the markup
    it "renders the same columns as the branches page" do
      create(:patch_ci_repo_state)
      create(:patch_branch, ci_status: "success", pushed_at: 1.hour.ago)

      get "/ci"
      dashboard = header_labels(response.body)

      get "/ci/branches"

      expect(dashboard).to eq([ "Result", "Branch", "Topic", "PG", "Base", "State", "Check",
                                "Tests", "Timing", "Try it", "Updated" ])
      expect(header_labels(response.body)).to eq(dashboard)
    end

    it "keeps in-flight rows out of recent results" do
      create(:patch_ci_repo_state)
      running = create(:patch_branch, ci_status: "running", pushed_at: 5.minutes.ago)
      done = create(:patch_branch, ci_status: "success", pushed_at: 1.hour.ago)

      get "/ci"

      # both appear on the page; only the terminal one is under #recent
      expect(section("recent")).to include(done.branch_name)
      expect(section("recent")).not_to include(running.branch_name)
    end

    # recent results moved from PatchCiRun.terminal to PatchBranch.current, so a
    # v1 row's result stops showing once v2 supersedes it. Intended - pinned so
    # a lost .current does not quietly bring the old verdicts back.
    it "leaves a superseded branch out of recent results" do
      create(:patch_ci_repo_state)
      current = create(:patch_branch, ci_status: "success", pushed_at: 10.minutes.ago)
      old = create(:patch_branch, ci_status: "tests_failed", pushed_at: 1.hour.ago,
                   superseded_by: current)

      get "/ci"

      expect(section("recent")).to include(current.branch_name)
      expect(section("recent")).not_to include(old.branch_name)
    end

    it "shows the base freshness tier on dashboard rows" do
      state = create(:patch_ci_repo_state, master_committed_at: Time.current)
      create(:patch_branch, ci_status: "success", pushed_at: 1.hour.ago,
             base_committed_at: state.master_committed_at - 400.days, base_commit_height: 5)

      get "/ci"

      expect(response.body).to include("ancient")
    end

    # the number is an intersection of two dimensions, so a row that satisfies
    # only one of them is the case worth pinning
    it "counts patchsets applying on the current master and checked against it" do
      state = create(:patch_ci_repo_state, master_committed_at: 2.days.ago)
      create(:patch_branch, ci_status: "success", pushed_at: 1.day.ago, on_master: true,
             base_sha: state.master_sha,
             base_committed_at: state.master_committed_at, last_master_apply_at: 1.hour.ago)
      # applies, but the last check predates this master
      create(:patch_branch, ci_status: "success", pushed_at: 1.day.ago, on_master: true,
             base_sha: state.master_sha,
             base_committed_at: state.master_committed_at, last_master_apply_at: 3.days.ago)
      # checked against this master, but conflicts
      create(:patch_branch, ci_status: "success", pushed_at: 1.day.ago, on_master: false,
             base_committed_at: state.master_committed_at, last_master_apply_at: 1.hour.ago)

      get "/ci"

      expect(stat_tile("Verified on master").at_css(".v").text.strip).to eq("1")
    end

    # the needs_rebase bucket's own sub-line: of the rows that failed on master,
    # the ones whose failure was against the master we have. The rest failed
    # against an older one and are waiting for their re-probe.
    it "counts the failures that were reached against the current master" do
      state = create(:patch_ci_repo_state, master_committed_at: 2.days.ago)
      # failed against this master: a verdict we can stand behind
      create(:patch_branch, ci_status: "success", pushed_at: 1.day.ago, on_master: true,
             base_sha: "f" * 40, base_committed_at: state.master_committed_at,
             master_apply_sha: state.master_sha,
             master_apply_error: "CONFLICT (content): Merge conflict in a.c")
      # failed, but against a master we have since moved past
      create(:patch_branch, ci_status: "success", pushed_at: 1.day.ago, on_master: true,
             base_sha: "e" * 40, base_committed_at: state.master_committed_at,
             master_apply_sha: "0" * 40,
             master_apply_error: "CONFLICT (content): Merge conflict in a.c")
      # applied when last tried and master has moved since: not a failure at all
      create(:patch_branch, ci_status: "success", pushed_at: 1.day.ago, on_master: true,
             base_sha: "d" * 40, base_committed_at: state.master_committed_at)

      get "/ci"

      bucket = Nokogiri::HTML(response.body).css(".ci-health .bucket")
                                           .find { |node| node.at_css(".t").text.strip == "needs rebase" }
      expect(bucket.at_css(".n").text.strip).to eq("2")
      failing = bucket.css("li").find { |li| li.text.include?("failing on this master") }
      expect(failing.css("span").last.text.strip).to eq("1")
    end

    # an empty apply is our bug, not a patchset that failed to build, so the
    # never_applied panel says how many of them there are rather than burying
    # them with the extract and conflict failures
    it "counts the patchsets that applied without changing anything" do
      create(:patch_ci_repo_state)
      create(:patch_branch, status: "failed", failure_stage: "empty",
             failure_reason: PatchBranches::Applier::UNSUPPORTED_FORMAT)
      create(:patch_branch, status: "failed", failure_stage: "apply",
             failure_reason: "patch does not apply")

      get "/ci"
      bucket = Nokogiri::HTML(response.body).css(".ci-health .bucket")
                                           .find { |node| node.at_css(".t").text.strip == "never applied" }

      expect(bucket.at_css(".n").text.strip).to eq("2")
      empty = bucket.css("li").find { |li| li.text.include?("applied but changed nothing") }
      expect(empty.css("span").last.text.strip).to eq("1")
    end

    it "warns on the status strip when rows have gone unchecked" do
      state = create(:patch_ci_repo_state, master_committed_at: 2.days.ago)
      create(:patch_branch, ci_status: "success", pushed_at: 1.day.ago, on_master: true,
             base_committed_at: state.master_committed_at, last_master_apply_at: 3.days.ago)

      get "/ci"

      tile = stat_tile("Verified on master")
      expect(tile.at_css(".d").text.strip)
        .to eq("1 not rechecked in #{PatchCi::Config::MASTER_CHECK_WARN_HOURS}h")
      # the red is the warning, not decoration on it
      expect(tile.at_css(".d")["class"].split).to include("ci-down")
    end

    # the planner never re-probes a retired row, so counting one as overdue
    # would put a permanent, growing floor under the warning. Both retired
    # shapes are here: an ancient failed row buckets as never_applied, an
    # ancient applied one as wont_retry.
    it "leaves retired rows out of the overdue warning" do
      state = create(:patch_ci_repo_state, master_committed_at: 2.days.ago)
      retired = state.master_committed_at - (PatchCi::Config::REBASE_AFTER_DAYS + 1).days
      create(:patch_branch, status: "failed", failure_stage: "apply", pushed_at: nil,
             base_committed_at: retired, last_master_apply_at: 3.days.ago)
      create(:patch_branch, ci_status: "success", pushed_at: 1.day.ago, on_master: true,
             base_committed_at: retired, last_master_apply_at: 3.days.ago)

      get "/ci"

      tile = stat_tile("Verified on master")
      expect(tile.at_css(".d").text.strip).to eq("applied on the current master")
      expect(tile.at_css(".ci-down")).to be_nil
    end

    it "describes the stat plainly while nothing is overdue" do
      state = create(:patch_ci_repo_state, master_committed_at: 2.days.ago)
      create(:patch_branch, ci_status: "success", pushed_at: 1.day.ago, on_master: true,
             base_committed_at: state.master_committed_at, last_master_apply_at: 1.hour.ago)

      get "/ci"

      tile = stat_tile("Verified on master")
      expect(tile.at_css(".d").text.strip).to eq("applied on the current master")
      expect(tile.at_css(".ci-down")).to be_nil
    end

    it "shows the master check tier on dashboard rows" do
      state = create(:patch_ci_repo_state, master_committed_at: 2.days.ago)
      create(:patch_branch, ci_status: "success", pushed_at: 1.hour.ago,
             last_master_apply_at: state.master_committed_at + 1.hour)

      get "/ci"
      headers, cells = first_table_row(response.body)

      expect(cells[headers.index("Check")].text.strip).to eq("current")
    end
  end

  describe "GET /ci/runs" do
    it "is gone" do
      get "/ci/runs"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /ci/branches" do
    it "renders for guests" do
      get "/ci/branches"
      expect(response).to have_http_status(:ok)
    end

    # every other cell assertion here is "this string is somewhere in this
    # section", which a td inserted, dropped or swapped without touching the th
    # list would still satisfy. One partial, so this covers all three tables.
    it "lines the cells up with the headers" do
      create(:patch_ci_repo_state)
      branch_with_run({ pg_major: 18, ci_status: "tests_failed", pushed_at: 1.hour.ago },
                      { status: "tests_failed", pg_major: 18 })

      get "/ci/branches"
      headers, cells = first_table_row(response.body)

      expect(cells.size).to eq(headers.size)
      expect(cells[headers.index("PG")].text.strip).to eq("18")
      expect(cells[headers.index("Result")].text.strip).to eq("tests failed")
    end

    it "renders the search box, the facet rows and the table frame" do
      create(:patch_ci_repo_state)
      create(:patch_branch, pg_major: 18)

      get "/ci/branches"

      expect(response.body).to include("ci-search")
      expect(response.body).to include("ci-facets")
      expect(response.body).to include(%(id="ci-branches"))
      # one chip per facet value, so all five rows are wired to the query
      expect(response.body).to include(%(href="/ci/branches?base=recent"))
      expect(response.body).to include(%(href="/ci/branches?state=applies"))
      expect(response.body).to include(%(href="/ci/branches?check=current"))
      expect(response.body).to include(%(href="/ci/branches?pg=18"))
      expect(response.body).to include(%(href="/ci/branches?result=success"))
      # a sortable header on a column that is not the current sort
      expect(response.body).to include(%(href="/ci/branches?dir=desc&amp;sort=pg"))
    end

    # rendered outside the frame, the chips and the form's hidden fields would
    # still hold the previous request's params after a frame navigation, and the
    # next click would drop whatever the last one added
    it "keeps the whole chrome inside the table frame" do
      # two pages, so kaminari renders a pager to find in there
      stub_const("PatchCi::Config::BRANCHES_PAGE", 1)
      create(:patch_ci_repo_state)
      2.times { create(:patch_branch) }

      get "/ci/branches"

      frame = response.body[/<turbo-frame [^>]*id="ci-branches".*?<\/turbo-frame>/m]
      expect(frame).not_to be_nil
      expect(frame).to include(%(<form class="ci-search"))
      expect(frame).to include(%(<div class="ci-facets">))
      expect(frame).to include(%(<table class="ci-table">))
      expect(frame).to include(%(<nav class="pagination"))
      # frame-level, so kaminari's own links advance the address bar too
      expect(frame).to match(/\A<turbo-frame [^>]*data-turbo-action="advance"/)
    end

    # the mechanism by which a search keeps the facets that are already applied
    it "carries the active facets and sort through the search form" do
      create(:patch_ci_repo_state)

      get "/ci/branches", params: { base: "recent", state: "applies", sort: "pg", dir: "asc" }

      form = response.body[/<form class="ci-search".*?<\/form>/m]
      expect(form).to include(%(<input type="hidden" name="base" value="recent"))
      expect(form).to include(%(<input type="hidden" name="state" value="applies"))
      expect(form).to include(%(<input type="hidden" name="sort" value="pg"))
      expect(form).to include(%(<input type="hidden" name="dir" value="asc"))
      # exactly one q, the visible one
      expect(form.scan(/name="q"/).size).to eq(1)
    end

    # the frame render replaces the form, so the input has to be carried over or
    # the debounced submit eats the caret every 300ms
    it "marks the search box permanent so a frame render keeps the caret" do
      get "/ci/branches"

      expect(response.body).to match(/<input[^>]*id="ci-q"[^>]*data-turbo-permanent/)
    end

    # turbo carries a permanent element across drive renders too, so only a real
    # browser navigation empties the search box
    it "clears filters with turbo declining the link" do
      get "/ci/branches", params: { state: "applies" }

      expect(response.body).to match(%r{data-turbo="false"[^>]*href="/ci/branches">clear filters})
    end

    it "toggles a facet value instead of replacing the filter" do
      create(:patch_ci_repo_state)
      create(:patch_branch)

      get "/ci/branches", params: { state: "applies" }

      # an inactive chip adds itself to what is already selected
      expect(response.body).to include(%(href="/ci/branches?state=applies%2Cwont_retry"))
      # the active chip drops its own value, leaving no empty state= behind
      expect(response.body).to match(%r{is-active[^>]*href="/ci/branches">applies})
      expect(response.body).to include("clear filters")
    end

    it "offers no clear filters link when nothing is filtered" do
      get "/ci/branches"

      expect(response.body).not_to include("clear filters")
    end

    # a sort is not a filter, and there is nothing to clear on a page that only
    # changed its column order
    it "offers no clear filters link for a sort alone" do
      get "/ci/branches", params: { sort: "pg", dir: "asc" }

      expect(response.body).not_to include("clear filters")
    end

    # the chips are run statuses, and the badges under them come from CI_BADGES
    it "labels result chips the way the table labels the same statuses" do
      get "/ci/branches"

      expect(response.body).to include(">waiting for runner<")
      expect(response.body).not_to include(">pushed awaiting ci<")
      expect(response.body).to include(">no CI<")
      # the NO_RESULT sentinel is not a status and must not read like one
      expect(response.body).to include(">no result<")
      expect(response.body).not_to include(">ci none<")
    end

    it "filters by base tier" do
      create(:patch_ci_repo_state, master_committed_at: Time.current)
      recent = create(:patch_branch, base_committed_at: 1.day.ago, base_commit_height: 10)
      ancient = create(:patch_branch, base_committed_at: 400.days.ago, base_commit_height: 5)

      get "/ci/branches", params: { base: "recent" }

      expect(response.body).to include(recent.branch_name)
      expect(response.body).not_to include(ancient.branch_name)
      expect(response.body).to include("showing 1 of 1 branches")
    end

    it "filters by state" do
      state = create(:patch_ci_repo_state)
      applies = create(:patch_branch, pushed_at: 1.day.ago, ci_status: "success",
                       base_sha: state.master_sha,
                       base_committed_at: 1.day.ago, base_commit_height: 10)
      failed = create(:patch_branch, status: "failed", failure_stage: "apply")

      get "/ci/branches", params: { state: "applies" }

      expect(response.body).to include(applies.branch_name)
      expect(response.body).not_to include(failed.branch_name)
    end

    it "ignores an unknown state filter" do
      applies = create(:patch_branch, pushed_at: 1.day.ago, ci_status: "success",
                       base_committed_at: 1.day.ago, base_commit_height: 10)

      get "/ci/branches", params: { state: "not_a_bucket" }

      expect(response.body).to include(applies.branch_name)
      expect(response.body).not_to include("clear filters")
    end

    # a bookmark holding a bucket name we have since renamed degrades to no
    # filter at all, rather than 500ing
    it "ignores a retired bucket name in the state filter" do
      applies = create(:patch_branch, pushed_at: 1.day.ago, ci_status: "success",
                       base_committed_at: 1.day.ago, base_commit_height: 10)

      get "/ci/branches", params: { state: "fresh" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(applies.branch_name)
      expect(response.body).not_to include("clear filters")
    end

    it "searches by topic title" do
      create(:patch_ci_repo_state)
      hit = create(:patch_branch, topic: create(:topic, title: "pg_upgrade cleanup"))
      miss = create(:patch_branch, topic: create(:topic, title: "vacuum tuning"))

      get "/ci/branches", params: { q: "upgra" }

      expect(response.body).to include(hit.branch_name)
      expect(response.body).not_to include(miss.branch_name)
      # the search survives a facet click
      expect(response.body).to include(%(href="/ci/branches?q=upgra&amp;state=applies"))
    end

    it "sorts by a requested column in both directions" do
      create(:patch_ci_repo_state)
      # updated_at runs opposite to pg_major, so the default sort cannot pass this
      high = create(:patch_branch, pg_major: 20, updated_at: 2.hours.ago)
      low = create(:patch_branch, pg_major: 15, updated_at: 1.hour.ago)

      get "/ci/branches", params: { sort: "pg", dir: "desc" }

      expect(response.body.index(high.branch_name)).to be < response.body.index(low.branch_name)

      get "/ci/branches", params: { sort: "pg", dir: "asc" }

      expect(response.body.index(low.branch_name)).to be < response.body.index(high.branch_name)
    end

    it "does not 500 on a huge page number" do
      get "/ci/branches", params: { page: "99999999999999999999" }
      expect(response).to have_http_status(:ok)
    end

    # a NUL is valid UTF-8, so check_param_encoding does not catch it and it
    # reaches quote_string, which raises
    it "does not 500 on a NUL in the search box" do
      get "/ci/branches", params: { q: "a#{0.chr}b" }
      expect(response).to have_http_status(:ok)
    end

    it "paginates" do
      stub_const("PatchCi::Config::BRANCHES_PAGE", 1)
      # newer created first, so id DESC alone would put it on page 2
      newer = create(:patch_branch, updated_at: 1.hour.ago)
      older = create(:patch_branch, updated_at: 2.hours.ago)

      get "/ci/branches"
      expect(response.body).to include(newer.branch_name)
      expect(response.body).not_to include(older.branch_name)

      get "/ci/branches", params: { page: 2 }
      expect(response.body).to include(older.branch_name)
    end

    it "keeps an active filter across pages" do
      stub_const("PatchCi::Config::BRANCHES_PAGE", 1)
      create(:patch_ci_repo_state, master_committed_at: Time.current)
      older = create(:patch_branch, updated_at: 2.hours.ago,
                     base_committed_at: 1.day.ago, base_commit_height: 10)
      newer = create(:patch_branch, updated_at: 1.hour.ago,
                     base_committed_at: 1.day.ago, base_commit_height: 10)
      ancient = create(:patch_branch, base_committed_at: 400.days.ago, base_commit_height: 5)

      get "/ci/branches", params: { base: "recent" }

      expect(response.body).to include(newer.branch_name)
      expect(response.body).to include("showing 1 of 2 branches")
      expect(response.body).to include(%(href="/ci/branches?base=recent&amp;page=2"))

      get "/ci/branches", params: { base: "recent", page: 2 }

      expect(response.body).to include(older.branch_name)
      expect(response.body).not_to include(newer.branch_name)
      expect(response.body).not_to include(ancient.branch_name)
    end

    it "loads branch rows with a single query against patch_branches" do
      create(:patch_ci_repo_state)
      5.times { create(:patch_branch) }

      queries = []
      sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        queries << payload[:sql]
      end
      get "/ci/branches"
      ActiveSupport::Notifications.unsubscribe(sub)

      # health_bucket only appears on the with_bucket row-select - an N+1
      # reimplementation (bucket_for per row) would show up as several of these
      row_selects = queries.select do |q|
        q.start_with?("SELECT") && q.include?(%("patch_branches")) && q.include?("health_bucket")
      end
      expect(row_selects.size).to eq(1)
    end

    it "sends the branch cell to github and the result cell to the history page" do
      create(:patch_ci_repo_state)
      row, = branch_with_run({ ci_status: "success", pushed_at: 1.hour.ago })

      get "/ci/branches"
      headers, cells = first_table_row(response.body)

      branch_cell = cells[headers.index("Branch")]
      expect(branch_cell.at_css("a")["href"])
        .to eq("https://github.com/hackorum-dev/postgres/tree/#{row.branch_name}")
      expect(cells[headers.index("Result")].at_css("a")["href"])
        .to eq(ci_topic_path(row.topic_id))
      # the topic cell keeps pointing at the thread
      expect(cells[headers.index("Topic")].at_css("a")["href"]).to eq(topic_path(row.topic_id))
      # inside a turbo frame a plain link renders the topic page INTO the frame,
      # which has no matching frame in it - the whole table would blank out
      expect(cells[headers.index("Result")].at_css("a")["data-turbo-frame"]).to eq("_top")
    end

    # the branch only exists in the local clone until it is pushed, so a link
    # would be a guaranteed 404
    it "does not link a branch that was never pushed" do
      create(:patch_ci_repo_state)
      create(:patch_branch, pushed_at: nil)

      get "/ci/branches"
      headers, cells = first_table_row(response.body)

      expect(cells[headers.index("Branch")].at_css("a")).to be_nil
      expect(response.body).not_to include("/hackorum-dev/postgres/tree/")
    end

    # a row with no CI result is exactly the row whose apply failure you want
    it "links the history page even with no result to show" do
      create(:patch_ci_repo_state)
      row = create(:patch_branch, ci_status: nil)

      get "/ci/branches"
      headers, cells = first_table_row(response.body)

      expect(cells[headers.index("Result")].at_css("a")["href"]).to eq(ci_topic_path(row.topic_id))
    end
  end

  describe "GET /ci/topics/:id" do
    # a topic with two patchsets: v1 superseded by v2, v2 pushed with a verdict
    def two_patchsets
      create(:patch_ci_repo_state, master_committed_at: Time.current)
      topic = create(:topic, last_message_at: Time.current)
      m1 = create(:message, topic: topic, created_at: 3.days.ago, is_patch_submission: true)
      m2 = create(:message, topic: topic, created_at: 1.hour.ago, is_patch_submission: true)
      v1 = create(:patch_branch, topic: topic, message: m1, branch_name: "t#{topic.id}_1")
      v2 = create(:patch_branch, topic: topic, message: m2, branch_name: "t#{topic.id}_2",
                  pushed_at: 30.minutes.ago, ci_status: "tests_failed",
                  base_committed_at: 2.days.ago, base_commit_height: 10)
      v1.update!(superseded_by: v2)
      [ topic, v1, v2 ]
    end

    def pushed_patchset(**attrs)
      # one clock for both ends of the gap: behind_days floors, so two
      # Time.current calls milliseconds apart would read as 11 days, not 12
      now = Time.current
      create(:patch_ci_repo_state, master_committed_at: now, master_commit_height: 1_000)
      topic = create(:topic, last_message_at: now)
      message = create(:message, topic: topic, created_at: 1.hour.ago, is_patch_submission: true)
      row = create(:patch_branch, topic: topic, message: message,
                   branch_name: "t#{topic.id}_1", on_master: false,
                   base_sha: "f4a2c91" + "0" * 33, base_source: "submission_head",
                   base_committed_at: now - 12.days, base_commit_height: 904,
                   pushed_at: 30.minutes.ago, pushed_head_sha: "9de17ab" + "0" * 33,
                   ci_status: "tests_failed", **attrs)
      [ topic, message, row ]
    end

    it "renders for guests" do
      topic, = two_patchsets

      get ci_topic_path(topic)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(topic.title)
    end

    it "404s for a topic that does not exist" do
      get "/ci/topics/0"

      expect(response).to have_http_status(:not_found)
    end

    it "says so for a topic with no patchsets" do
      get ci_topic_path(create(:topic))

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("no patchsets tracked for this topic")
    end

    it "heads the page with the count and the current branch" do
      _topic, _v1, v2 = two_patchsets

      get ci_topic_path(v2.topic)

      expect(response.body).to include("2 patchsets tracked")
      expect(response.body).to include(v2.branch_name)
      expect(response.body).to include("tests failed")
    end

    it "opens the current patchset" do
      topic, _v1, _v2 = two_patchsets

      get ci_topic_path(topic)
      sections = Nokogiri::HTML(response.body).css("details.ci-patchset")

      # only v2 is a fold: v1 never ran and never pushed, so it stays one line
      expect(sections.size).to eq(1)
      expect(sections.first.attribute("open")).to be_present
    end

    it "folds a superseded patchset that has something behind the fold" do
      topic, v1, = two_patchsets
      v1.update!(pushed_at: 4.days.ago, ci_status: "success")

      get ci_topic_path(topic)
      sections = Nokogiri::HTML(response.body).css("details.ci-patchset")

      expect(sections.size).to eq(2)
      expect(sections.first.attribute("open")).to be_present
      expect(sections.last.attribute("open")).to be_nil
    end

    # supersede fires only on a successful push, so two unpushed patchsets are
    # both "not superseded" - only the newest is current
    it "opens only the newest of two patchsets that were never pushed" do
      create(:patch_ci_repo_state)
      topic = create(:topic, last_message_at: Time.current)
      [ [ 1, 3.days.ago ], [ 2, 1.hour.ago ] ].each do |index, posted|
        message = create(:message, topic: topic, created_at: posted, is_patch_submission: true)
        create(:patch_branch, topic: topic, message: message,
               branch_name: "t#{topic.id}_#{index}", ci_status: "success", pushed_at: posted)
      end

      get ci_topic_path(topic)
      sections = Nokogiri::HTML(response.body).css("details.ci-patchset")

      expect(sections.size).to eq(2)
      expect(sections.first.attribute("open")).to be_present
      expect(sections.last.attribute("open")).to be_nil
    end

    # v1 was never pushed and never ran: there is nothing to expand, so it is
    # one line rather than an empty accordion
    it "reduces a patchset that never ran to a single line" do
      topic, v1, = two_patchsets

      get ci_topic_path(topic)
      quiet = Nokogiri::HTML(response.body).at_css(".ci-patchset.quiet")

      expect(quiet.text).to include(v1.branch_name)
      expect(quiet.text).to include("applied, never pushed")
      expect(quiet.text).to include("superseded")
    end

    it "names the failing stage of a patchset that never applied" do
      create(:patch_ci_repo_state)
      topic = create(:topic, last_message_at: Time.current)
      create(:patch_branch, topic: topic, status: "failed", failure_stage: "apply",
             failure_reason: "conflict in src/bin/pg_dump/t/002_pg_dump.pl")

      get ci_topic_path(topic)

      expect(response.body).to include("apply failed")
      expect(response.body).to include("conflict in src/bin/pg_dump")
    end

    it "numbers each patchset from its branch name" do
      topic, = two_patchsets

      get ci_topic_path(topic)

      expect(response.body).to include("v2")
      expect(response.body).to include("v1")
    end

    it "links the base sha at upstream and says how far behind it is" do
      topic, _message, row = pushed_patchset

      get ci_topic_path(topic)

      expect(response.body).to include("https://github.com/postgres/postgres/commit/#{row.base_sha}")
      expect(response.body).to include("f4a2c9100")
      expect(response.body).to include("12 days / 96 commits behind master")
      expect(response.body).to include("(from submission head)")
    end

    # on_master implies base_source master and a 0/0 behind figure; saying all
    # three is how 1300+ real rows would read
    it "says a master-based patchset is on master and leaves it at that" do
      create(:patch_ci_repo_state, master_committed_at: Time.current)
      topic = create(:topic, last_message_at: Time.current)
      create(:patch_branch, topic: topic, on_master: true, base_source: "master",
             base_sha: "e395fbd" + "0" * 33, pushed_at: 1.hour.ago, ci_status: "success")

      get ci_topic_path(topic)

      expect(response.body).to include("on master")
      expect(response.body).not_to include("(from master)")
      expect(response.body).not_to include("0 commits behind")
    end

    it "links the branch, the pushed commit and the diff against the base" do
      topic, _message, row = pushed_patchset

      get ci_topic_path(topic)

      expect(response.body).to include("/hackorum-dev/postgres/tree/#{row.branch_name}")
      expect(response.body).to include("/hackorum-dev/postgres/commit/#{row.pushed_head_sha}")
      expect(response.body)
        .to include("/hackorum-dev/postgres/compare/#{row.base_sha}...#{row.pushed_head_sha}")
    end

    it "offers no diff link when the row was never pushed" do
      create(:patch_ci_repo_state)
      topic = create(:topic, last_message_at: Time.current)
      create(:patch_branch, topic: topic, base_sha: "aaa111", ci_status: "ci_none",
             ci_skip_reason: "thread inactive")

      get ci_topic_path(topic)

      expect(response.body).not_to include("/compare/")
      expect(response.body).to include("thread inactive")
    end

    it "spells out an apply failure with its conflicts" do
      create(:patch_ci_repo_state)
      topic = create(:topic, last_message_at: Time.current)
      create(:patch_branch, topic: topic, status: "failed", failure_stage: "apply",
             failure_reason: "patch does not apply",
             conflict_files: [ "src/backend/parser/gram.y" ], pushed_at: 1.hour.ago)

      get ci_topic_path(topic)

      expect(response.body).to include("apply failed")
      expect(response.body).to include("patch does not apply")
      expect(response.body).to include("src/backend/parser/gram.y")
    end

    it "reports a master re-apply that is failing" do
      topic, _message, = pushed_patchset(master_apply_error: "conflict in gram.y",
                                         last_master_apply_at: 2.hours.ago)

      get ci_topic_path(topic)

      expect(response.body).to include("conflict in gram.y")
    end

    # which master it failed on is the whole value of the record: without it the
    # error could be about any of the several masters we see in a day
    it "names the master a failing re-apply was tried against, and where" do
      topic, _message, = pushed_patchset(master_apply_error: "conflict in gram.y",
                                         master_apply_sha: "abc1234" + "0" * 33,
                                         master_conflict_files: [ "src/backend/parser/gram.y" ],
                                         last_master_apply_at: 2.hours.ago)

      get ci_topic_path(topic)
      rebase = Nokogiri::HTML(response.body).css(".ci-fact")
                                           .find { |node| node.at_css(".k").text.strip == "rebase" }

      expect(rebase.text).to include("abc12340")
      expect(rebase.text).to include("src/backend/parser/gram.y")
    end

    it "leaves the rebase row out when master re-apply never ran" do
      topic, = pushed_patchset

      get ci_topic_path(topic)
      facts = Nokogiri::HTML(response.body).css(".ci-fact .k").map(&:text)

      expect(facts).to include("base", "apply", "push", "patchset")
      expect(facts).not_to include("rebase")
    end

    it "links the patchset download and the message in the thread" do
      topic, message, = pushed_patchset

      get ci_topic_path(topic)

      expect(response.body).to include(message_patchset_path(message))
      expect(response.body).to include("#{topic_path(topic)}#message-#{message.id}")
    end

    it "tables the runs of a patchset, newest first" do
      topic, _message, row = pushed_patchset
      # both finished: the table sorts on finish time, and a run still out
      # there tops the list rather than sorting by run id
      old = create(:patch_ci_run, patch_branch: row, github_run_id: 100,
                   status: "build_failed", build_seconds: 182, completed_at: 1.day.ago)
      new = create(:patch_ci_run, patch_branch: row, github_run_id: 200,
                   status: "tests_failed", pg_major: 11, tests_total: 440,
                   failed_tests: [ "pg_dump/002_pg_dump.pl" ],
                   build_seconds: 371, test_seconds: 663, completed_at: 2.hours.ago)

      get ci_topic_path(topic)
      table = Nokogiri::HTML(response.body).at_css(".ci-runs table.ci-table")
      headers = table.css("th").map { |th| th.text.strip }
      first_row = table.css("tr")[1].css("td").map { |td| td.text.strip }

      expect(headers).to eq([ "Result", "Att", "PG", "Tests", "Build / test", "Image", "When" ])
      expect(first_row[headers.index("Result")]).to eq("tests failed")
      expect(first_row[headers.index("Tests")]).to eq("439 / 440")
      expect(first_row[headers.index("Build / test")]).to eq("6m 11s / 11m 03s")
      expect(table.at_css("tr.ci-run-more td")["colspan"].to_i).to eq(table.css("th").size)
      # by run link, not by bare id: "100" also appears in durations and heights
      expect(response.body.index("/actions/runs/#{new.github_run_id}"))
        .to be < response.body.index("/actions/runs/#{old.github_run_id}")
    end

    it "has no runs table for a patchset that never ran" do
      topic, = pushed_patchset

      get ci_topic_path(topic)

      expect(Nokogiri::HTML(response.body).at_css(".ci-runs")).to be_nil
    end

    it "expands a run into its failures, counters and links" do
      topic, _message, row = pushed_patchset
      create(:patch_ci_run, patch_branch: row, github_run_id: 18_273_641_923, run_attempt: 2,
             status: "tests_failed", tests_total: 440, failed_tests: [ "pg_dump/002_pg_dump.pl" ],
             head_sha: "9de17ab" + "0" * 33, completed_at: 2.hours.ago,
             image_digest: "sha256:1f9c" + "0" * 60,
             payload: { "ccache" => { "hit" => 8412, "miss" => 213 } })

      get ci_topic_path(topic)
      detail = Nokogiri::HTML(response.body).at_css(".ci-run-detail").text

      expect(detail).to include("pg_dump/002_pg_dump.pl")
      expect(detail).to include("executed 440")
      expect(detail).to include("ccache 8412 hit / 213 miss")
      expect(detail).to include("9de17ab00")
      expect(detail).to include("sha256:1f9c")
      expect(response.body)
        .to include("/actions/runs/18273641923/attempts/2")
    end

    it "shows why a payload was rejected" do
      topic, _message, row = pushed_patchset
      create(:patch_ci_run, patch_branch: row, status: "infra_error",
             payload: { "ingest_error" => "malformed json: unexpected token" })

      get ci_topic_path(topic)

      expect(response.body).to include("malformed json: unexpected token")
    end

    # one tag per topic: the newest run holding an image owns it, everything
    # older can only be pulled by digest
    it "offers the tag to the newest image and digests to the rest" do
      topic, _message, row = pushed_patchset
      create(:patch_ci_run, patch_branch: row, github_run_id: 100,
             image_ref: "ghcr.io/hackorum-dev/postgres-patch:t#{topic.id}",
             image_digest: "sha256:aaa" + "0" * 61)
      create(:patch_ci_run, patch_branch: row, github_run_id: 200,
             image_ref: "ghcr.io/hackorum-dev/postgres-patch:t#{topic.id}",
             image_digest: "sha256:bbb" + "0" * 61)

      get ci_topic_path(topic)

      expect(response.body).to include("postgres-patch:t#{topic.id}")
      expect(response.body).to include("postgres-patch@sha256:aaa")
      expect(response.body).not_to include("postgres-patch@sha256:bbb")
    end
  end

  describe "GET /ci/stats" do
    it "renders for guests with an empty database" do
      get "/ci/stats"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Patch CI statistics")
      expect(response.body).to include("Pipeline")
      expect(response.body).to include("Corpus")
    end

    it "renders without a repo state" do
      create(:patch_branch)

      get "/ci/stats"

      expect(response).to have_http_status(:ok)
    end

    it "marks the selected range control active and keeps the other params" do
      get "/ci/stats?range=30d&active=active"

      body = Nokogiri::HTML(response.body)
      active = body.css(".ci-stats-controls a.is-active").map { |a| a[:href] }
      expect(active).to include(a_string_matching(/range=30d/))
      expect(active).to include(a_string_matching(/active=active/))
    end

    it "links to the stats page from the dashboard sidebar" do
      get "/ci"

      expect(response.body).to include(%(href="/ci/stats"))
    end

    it "renders the run volume and success rate blocks with a table twin" do
      branch = create(:patch_branch)
      create(:patch_ci_run, patch_branch: branch, status: "success",
                            completed_at: 2.hours.ago)

      get "/ci/stats"

      body = Nokogiri::HTML(response.body)
      expect(body.at_css("#runs-by-status .ci-chart")["data-ci-chart-spec-value"]).to include("vega-lite")
      expect(body.at_css("#runs-by-status table.ci-table").text).to include("success")
      expect(body.at_css("#success-rate table.ci-table").text).to include("100")
    end

    it "renders the no-data note for a window with no runs" do
      get "/ci/stats?range=24h"

      expect(Nokogiri::HTML(response.body).at_css("#runs-by-status").text)
        .to include("no data in this range")
    end

    it "renders the corpus panel with both base age series" do
      create(:patch_ci_repo_state)
      create(:patch_branch, base_committed_at: 2.days.ago)

      get "/ci/stats"

      table = Nokogiri::HTML(response.body).at_css("#base-age table.ci-table")
      expect(table.text).to include("Active discussions")

      # the branch's topic gets a message 1 week ago by factory default, so it
      # counts in both series - a bare label check would pass even at zero rows
      row = table.css("tr").find { |tr| tr.text.include?("1-7d") }
      expect(row.css("td").map(&:text)).to eq([ "1-7d", "1", "1" ])
    end

    it "renders the master re-check recency block" do
      create(:patch_ci_repo_state, master_committed_at: 2.days.ago)
      create(:patch_branch, last_master_apply_at: 3.days.ago)

      get "/ci/stats"

      block = Nokogiri::HTML(response.body).at_css("#master-check")
      expect(block.at_css("h3").text).to eq("Master re-check recency")
      bar = block.css(".ci-stats-bar").find { |row| row.at_css(".label").text.strip == "overdue" }
      expect(bar.at_css(".n").text.strip).to eq("1")
    end

    it "renders the pipeline tiles and the infra health table" do
      get "/ci/stats"

      expect(response.body).to include("Median queue wait")
      expect(Nokogiri::HTML(response.body).at_css("#infra-health").text).to include("built but pushed no image")
    end

    # the axis field is a count rendered as a nominal label, so without an
    # explicit domain vega orders it as text and 10 lands before 2
    it "orders the suites-failed axis numerically" do
      [ 1, 2, 10 ].each do |count|
        branch_with_run({}, { status: "tests_failed", completed_at: 1.hour.ago,
                              failed_tests: Array.new(count) { |i| "regress/t#{i}" } })
      end

      get "/ci/stats"

      spec = Nokogiri::HTML(response.body)
                     .at_css("#failure-concentration .ci-chart")["data-ci-chart-spec-value"]
      expect(JSON.parse(spec).dig("encoding", "x", "sort")).to eq(%w[1 2 10])
    end

    it "does not issue a query per rendered block" do
      create(:patch_ci_repo_state)
      3.times do
        branch_with_run({ base_committed_at: 10.days.ago, pg_major: 20 },
                        { status: "success", completed_at: 2.hours.ago, build_seconds: 100,
                          test_seconds: 200, tests_total: 900 })
      end

      # a generous ceiling: the point is to catch a per-row or per-block query,
      # not to pin the exact count. Raise it deliberately if you add aggregates.
      # 46 as of this commit
      queries = captured_queries { get "/ci/stats" }

      expect(response).to have_http_status(:ok)
      expect(queries.size).to be < 80
    end
  end
end
