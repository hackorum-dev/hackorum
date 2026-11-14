require "rails_helper"

RSpec.describe "API v1 lineage", type: :request do
  let(:alice) { create(:alias, :with_sent_messages, name: "Alice A", email: "alice.a@example.org") }
  let(:tom) { create(:alias, :with_sent_messages, name: "Tom Lane", email: "tgl@example.org").person }
  let(:topic) { create(:topic, creator_alias: alice, title: "Add a feature", slug: "add-feature") }
  let(:start) { Time.zone.parse("2026-03-01 10:00:00") }
  let(:reader) { create(:user) }
  let(:reader_headers) { bearer(reader) }

  let(:sha_a) { "a" * 40 }
  let(:sha_b) { "b" * 40 }
  let(:sha_c) { "c" * 40 }
  let(:m1) { patchset }
  let(:m2) { patchset(at: start + 1.hour) }
  # a patchset that only the old run has a step for
  let(:old_only) { patchset(at: start + 90.minutes) }
  let(:run) do
    create(:patchset_run, topic: topic, model: "gpt-6-test", created_at: start + 1.day,
                          finished_at: Time.zone.parse("2026-03-02 10:10:00"), story: story)
  end
  let(:story) do
    "v1 posted in [msg:#{m1.id}]\n\n  rebased as [msg:#{m2.id}], see [msg:#{m1.id}]; landed as [commit:#{sha_c}] \n" \
      "\nplain line\n"
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

  def error_code
    body.dig("error", "code")
  end

  # the first request of a token also stamps its use
  def warm_up
    get "/api/v1/me", headers: reader_headers
  end

  def patchset(at: start, in_topic: topic, sender: alice)
    row = create(:message, topic: in_topic, sender: sender, created_at: at)
    row.update_columns(is_patch_submission: true)
    row
  end

  def step(message, in_run: run, **attrs)
    create(:patchset_lineage, patchset_run: in_run, topic: in_run.topic, message: message, **attrs)
  end

  def commit(sha, at: start, source: "trailer", **attrs)
    row = create(:commit, sha: sha, committed_at: at, **attrs)
    create(:commit_topic, commit: row, topic: topic, source: source)
    row
  end

  def credit(row, role, name, person: nil, **attrs)
    row.commit_people.create!(role: role, raw_name: name, raw_email: "#{name.parameterize}@example.com",
                              person: person, **attrs)
  end

  def people(row)
    row["people"].map { |entry| entry.values_at("role", "name", "source") }
  end

  def reviews(final)
    [ { "reviewer" => "Alice", "reviewed_message_ids" => [ final.id ], "coverage" => "final",
        "note" => "looked at [msg:#{final.id}]", "source" => "trailer" },
      { "reviewer" => "Bob", "reviewed_message_ids" => [], "coverage" => "earlier", "note" => nil },
      { "reviewer" => "Guessed Reviewer", "reviewed_message_ids" => [ final.id ], "coverage" => "final",
        "note" => "tested it", "source" => "llm", "reviewer_message_id" => nil, "confidence" => 0.8 } ]
  end

  # a thread with a story, steps, an llm link, llm credits and verdicts
  def lineage_thread(old_step: false)
    old = create(:patchset_run, topic: topic, created_at: start, story: "old story")
    step(m1, in_run: old, step_kind: "resend", reason: "old reason")
    step(old_only, in_run: old, step_kind: "fix_on_top", reason: "old reason") if old_step
    step(m1, step_kind: "new_series", confidence: 1.0, reason: "first version")
    step(m2, parent_message: m1, step_kind: "rebase", confidence: 0.85, reason: "same hunks as [msg:#{m1.id}]")
    create(:patchset_run, topic: topic, status: "failed", created_at: start + 2.days, story: "failed story")

    named = commit(sha_a, at: start + 3.days, subject: "Named change")
    credit(named, "author", "Named Author")
    credit(named, "committer", "Tom Lane", person: tom)
    credit(named, "reviewer", "Tom Lane", person: tom, source: "committer")
    credit(named, "reviewer", "Zed Reviewer")
    credit(named, "reviewer", "Zed Reviewer", source: "llm", confidence: 0.7)

    guessed = commit(sha_b, at: start + 2.days, subject: "Unnamed author")
    credit(guessed, "author", "Guessed Author", source: "llm", confidence: 0.9)
    credit(guessed, "committer", "Tom Lane", person: tom)
    credit(guessed, "reviewer", "Tom Lane", person: tom, source: "committer")

    linked = commit(sha_c, at: start + 1.day, source: "llm", subject: "Guessed link")
    credit(linked, "author", "Other Author")
    credit(linked, "reviewer", "Guessed Reviewer", source: "llm", confidence: 0.8)
    create(:commit_verdict, patchset_run: run, topic: topic, commit: linked, verdict: "modified", source_message: m2,
                            confidence: 0.9, change_level: "moderate", evidence: "hunks from [msg:#{m2.id}]",
                            reviewers_final: 2, reviewers_earlier: 1, reviewers_none: 0, reviews: reviews(m2))
    create(:commit_verdict, patchset_run: run, topic: topic, commit: guessed, verdict: "undecided", confidence: 0.5,
                            evidence: nil)
    create(:commit_verdict, patchset_run: run, topic: topic, commit: create(:commit, subject: "Unrelated overlap"),
                            verdict: "not_this_thread", origin: "overlap", confidence: 0.7)
    create(:commit_verdict, patchset_run: old, topic: topic, commit: named, verdict: "as_is", evidence: "old verdict")
  end

  describe "GET /topics/{id}/lineage" do
    it "gives the run, the story by line and the steps of that run" do
      lineage_thread(old_step: true)

      get "/api/v1/topics/#{topic.id}/lineage", headers: reader_headers

      expect(response).to have_http_status(:ok)
      expect(body.keys).to match_array(%w[run story steps])
      expect(body["run"]).to eq("id" => run.id, "model" => "gpt-6-test", "finished_at" => "2026-03-02T10:10:00.000Z")
      expect(body["story"]).to eq([
        { "text" => "v1 posted in [msg:#{m1.id}]", "message_ids" => [ m1.id ], "commit_shas" => [] },
        { "text" => "rebased as [msg:#{m2.id}], see [msg:#{m1.id}]; landed as [commit:#{sha_c}]",
          "message_ids" => [ m2.id, m1.id ], "commit_shas" => [ sha_c ] },
        { "text" => "plain line", "message_ids" => [], "commit_shas" => [] }
      ])
      expect(body["steps"]).to eq([
        { "message_id" => m1.id, "parent_message_id" => nil, "step_kind" => "new_series", "confidence" => 1.0,
          "reason" => "first version" },
        { "message_id" => m2.id, "parent_message_id" => m1.id, "step_kind" => "rebase", "confidence" => 0.85,
          "reason" => "same hunks as [msg:#{m1.id}]" }
      ])
      expect(body["steps"].map { |row| row["step_kind"] }).to eq(%w[new_series rebase])
      expect(body["steps"].map { |row| row["message_id"] }).not_to include(old_only.id)
      expect(PatchsetLineage.where(topic: topic).pluck(:step_kind)).to match_array(%w[resend fix_on_top new_series rebase])
      expect(response.body).not_to include("old story", "old reason", "failed story")
    end

    it "lists each reference of a line once, in order of appearance" do
      run.update!(story: "[commit:#{sha_c}] [msg:#{m2.id}] [commit:#{sha_a}] [msg:#{m2.id}] [commit:#{sha_c}] [msg:abc]")

      get "/api/v1/topics/add-feature/lineage", headers: reader_headers

      expect(body["story"].size).to eq(1)
      expect(body["story"].first).to include("message_ids" => [ m2.id ], "commit_shas" => [ sha_c, sha_a ])
      expect(body["steps"]).to eq([])
    end

    it "gives an empty story for a run without one" do
      run.update!(story: nil, model: nil)

      get "/api/v1/topics/#{topic.id}/lineage", headers: reader_headers

      expect(response).to have_http_status(:ok)
      expect(body).to include("story" => [], "steps" => [])
      expect(body["run"]).to include("model" => nil)
    end

    it "answers 404 when the thread has no finished run" do
      create(:patchset_run, topic: topic, status: "running", finished_at: nil)
      create(:patchset_run, topic: create(:topic, creator_alias: alice))

      get "/api/v1/topics/#{topic.id}/lineage", headers: reader_headers

      expect(response).to have_http_status(:not_found)
      expect(error_code).to eq("not_found")
    end

    it "answers 404 for an unknown thread and 301 for a merged one, whoever asks" do
      source = create(:topic, creator_alias: alice, merged_into_topic_id: topic.id)

      [ {}, reader_headers ].each do |headers|
        get "/api/v1/topics/nope/lineage", headers: headers
        expect(response).to have_http_status(:not_found)

        get "/api/v1/topics/#{source.id}/lineage", headers: headers
        expect(response).to have_http_status(:moved_permanently)
        expect(response.headers["Location"]).to end_with("/api/v1/topics/#{topic.id}/lineage")
      end
    end

    it "takes no query parameters" do
      run

      get "/api/v1/topics/#{topic.id}/lineage?limit=5", headers: reader_headers

      expect(response).to have_http_status(:bad_request)
      expect(error_code).to eq("invalid_parameter")
    end

    it "runs the same queries for a short story and a long one, and does not write" do
      run.update!(story: "one line [msg:#{m1.id}]")
      step(m1)
      warm_up
      short = captured_queries { get "/api/v1/topics/#{topic.id}/lineage", headers: reader_headers }
      expect(body["steps"].size).to eq(1)

      later = Array.new(4) { |i| patchset(at: start + (i + 2).hours) }
      later.each_with_index { |row, i| step(row, parent_message: ([ m1 ] + later)[i], step_kind: "minor_revision") }
      run.update!(story: ([ m1 ] + later).map { |row| "line [msg:#{row.id}] [commit:#{sha_a}]" }.join("\n\n"))
      long = captured_queries { get "/api/v1/topics/#{topic.id}/lineage", headers: reader_headers }

      expect(body["story"].size).to eq(5)
      expect(body["steps"].size).to eq(5)
      expect(body["steps"].map { |row| row["message_id"] }).to eq(([ m1 ] + later).map(&:id))
      expect(long.size).to eq(short.size)
      expect(long.grep(/\A\s*(INSERT|DELETE)/i)).to be_empty
      expect(long.grep(/\A\s*UPDATE/i).grep_v(/"api_tokens"/)).to be_empty
    end
  end

  describe "the queries of the lineage data, by table" do
    let(:tables) { %w[user_features team_features patchset_runs commit_verdicts patchset_lineages] }

    before do
      lineage_thread
      warm_up
    end

    def queries_for(path, headers)
      queries = captured_queries { get path, headers: headers }
      expect(response).to have_http_status(:ok)
      queries
    end

    def by_table(path, headers)
      queries = queries_for(path, headers)
      tables.index_with { |table| queries.grep(/FROM "#{table}"/).size }.reject { |_, count| count.zero? }
    end

    def expect_tables(path, with:)
      expect(by_table(path, {})).to eq(with), path
      expect(by_table(path, reader_headers)).to eq(with), path
    end

    it "are the run and its verdicts on the commits" do
      expect_tables("/api/v1/topics/#{topic.id}/commits", with: { "patchset_runs" => 1, "commit_verdicts" => 1 })
    end

    it "are the runs and the steps on patchsets" do
      [ "/api/v1/topics/#{topic.id}/patchsets", "/api/v1/people/alice.a@example.org/patchsets" ].each do |path|
        expect_tables(path, with: { "patchset_runs" => 1, "patchset_lineages" => 1 })
      end
    end

    it "are whether there is a run on the thread" do
      expect_tables("/api/v1/topics/#{topic.id}", with: { "patchset_runs" => 1 })
    end

    it "are the run and its steps on the lineage" do
      expect(by_table("/api/v1/topics/#{topic.id}/lineage", reader_headers))
        .to eq("patchset_runs" => 1, "patchset_lineages" => 1)
    end

    it "select no raw result of a run and no commit body" do
      run.update_columns(raw_result: { "marker" => "raw-result-marker" })
      Commit.update_all(body: "commit-body-marker")
      paths = %w[lineage commits patchsets].map { |name| "/api/v1/topics/#{topic.id}/#{name}" } + [ "/api/v1/topics/#{topic.id}" ]

      paths.each do |path|
        queries = queries_for(path, reader_headers)

        expect(queries.grep(/raw_result|bundle_index|"patchset_runs"\.\*/)).to eq([]), path
        expect(queries.grep(/"commits"\."body"|"commits"\.\*|commits\.\*/)).to eq([]), path
        expect(queries.grep(/"commit_verdicts"\.\*/)).to eq([]), path
        expect(response.body).not_to include("raw-result-marker", "commit-body-marker")
      end
      expect(queries_for("/api/v1/topics/#{topic.id}/lineage", reader_headers).grep(/FROM "patchset_runs"/).sole)
        .to start_with('SELECT "patchset_runs"."id", "patchset_runs"."topic_id", "patchset_runs"."model", ' \
                       '"patchset_runs"."finished_at", "patchset_runs"."story" FROM')
      expect(queries_for("/api/v1/topics/#{topic.id}/commits", reader_headers).grep(/FROM "commits"/).size).to eq(1)
    end
  end

  describe "GET /topics/{id}/commits" do
    it "adds the llm links and credits, where each comes from, and the verdicts" do
      lineage_thread

      get "/api/v1/topics/#{topic.id}/commits", headers: reader_headers

      expect(response).to have_http_status(:ok)
      expect(data.map { |row| row["sha"] }).to eq([ sha_a, sha_b, sha_c ])
      expect(data.map(&:keys)).to all(match_array(
        %w[sha subject committed_at committer_name url branches people link_source verdict]
      ))
      expect(data.map { |row| row["link_source"] }).to eq(%w[trailer trailer llm])
      expect(data.map { |row| people(row) }).to eq([
        [ [ "author", "Named Author", "parsed" ], [ "reviewer", "Tom Lane", "committer" ],
          [ "reviewer", "Zed Reviewer", "parsed" ], [ "committer", "Tom Lane", "parsed" ] ],
        [ [ "author", "Guessed Author", "llm" ], [ "reviewer", "Tom Lane", "committer" ],
          [ "committer", "Tom Lane", "parsed" ] ],
        [ [ "author", "Other Author", "parsed" ], [ "reviewer", "Guessed Reviewer", "llm" ] ]
      ])
      expect(data.flat_map { |row| row["people"].map(&:keys) }).to all(match_array(%w[role name person source]))
      expect(data.first["verdict"]).to be_nil
      expect(data.second["verdict"]).to eq(
        "verdict" => "undecided", "confidence" => 0.5, "change_level" => nil, "origin" => "trailer",
        "source_message_id" => nil, "evidence" => nil, "reviewers_final" => 0, "reviewers_earlier" => 0,
        "reviewers_none" => 0, "reviews" => []
      )
      expect(data.last["verdict"]).to eq(
        "verdict" => "modified", "confidence" => 0.9, "change_level" => "moderate", "origin" => "trailer",
        "source_message_id" => m2.id, "evidence" => "hunks from [msg:#{m2.id}]", "reviewers_final" => 2,
        "reviewers_earlier" => 1, "reviewers_none" => 0,
        "reviews" => [
          { "reviewer" => "Alice", "coverage" => "final", "source" => "trailer", "note" => "looked at [msg:#{m2.id}]" },
          { "reviewer" => "Bob", "coverage" => "earlier", "source" => nil, "note" => nil },
          { "reviewer" => "Guessed Reviewer", "coverage" => "final", "source" => "llm", "note" => "tested it" }
        ]
      )
      expect(response.body).not_to include("Unrelated overlap", "old verdict", "not_this_thread", "reviewed_message_ids")
    end

    it "calls a group trailer-linked when any of its commits is, and gives it the verdict of a backport" do
      commit(sha_a, source: "llm", subject: "On master")
      backport = commit(sha_b, at: start + 1.hour, cherry_picked_from_sha: sha_a, branches: [ "REL_18_STABLE" ])
      commit(sha_c, at: start - 1.day, source: "llm")
      create(:commit_verdict, patchset_run: run, topic: topic, commit: backport, verdict: "as_is", evidence: "same")

      get "/api/v1/topics/#{topic.id}/commits", headers: reader_headers

      expect(data.map { |row| row.values_at("sha", "link_source") }).to eq([ [ sha_a, "trailer" ], [ sha_c, "llm" ] ])
      expect(data.first["verdict"]).to include("verdict" => "as_is", "evidence" => "same")
      expect(data.last["verdict"]).to be_nil
    end

    it "gives no verdict that says the commit is not of this thread, or an undecided one that no trailer backs" do
      commit(sha_a, subject: "Linked by trailer")
      elsewhere = commit(sha_b, at: start + 1.day, subject: "Linked, judged to be of another thread")
      overlap = commit(sha_c, at: start + 2.days, source: "llm", subject: "Undecided overlap")
      create(:commit_verdict, patchset_run: run, topic: topic, commit: elsewhere, verdict: "not_this_thread", evidence: "evidence-marker")
      create(:commit_verdict, patchset_run: run, topic: topic, commit: overlap, verdict: "undecided", origin: "overlap")

      get "/api/v1/topics/#{topic.id}/commits", headers: reader_headers

      expect(data.map { |row| row["sha"] }).to eq([ sha_c, sha_b, sha_a ])
      expect(data.map { |row| row.fetch("verdict") }).to eq([ nil, nil, nil ])
      expect(response.body).not_to include("not_this_thread", "evidence-marker")

      CommitVerdict.where(commit: elsewhere).update_all(verdict: "partial")
      get "/api/v1/topics/#{topic.id}/commits", headers: reader_headers
      expect(data.second["verdict"]).to include("verdict" => "partial", "evidence" => "evidence-marker")
    end

    it "gives the verdicts the thread page of the site shows, for every kind and origin" do
      kinds = CommitVerdict::VERDICTS.product(CommitVerdict::ORIGINS)
      kinds.each_with_index do |(verdict, origin), index|
        row = commit(format("%040x", index + 1), at: start + index.hours, source: index.odd? ? "llm" : "trailer")
        create(:commit_verdict, patchset_run: run, topic: topic, commit: row, verdict: verdict, origin: origin,
                                evidence: "#{verdict} by #{origin}", reviewers_final: index.even? ? nil : 1,
                                reviews: index.even? ? nil : reviews(m1))
      end
      master = commit("d" * 40, at: start - 1.day, subject: "On master")
      backport = commit("e" * 40, at: start - 1.day + 1.hour, cherry_picked_from_sha: master.sha, branches: [ "REL_18_STABLE" ])
      second = commit("f" * 40, at: start - 1.day + 2.hours, cherry_picked_from_sha: master.sha, branches: [ "REL_17_STABLE" ])
      create(:commit_verdict, patchset_run: run, topic: topic, commit: backport, verdict: "as_is", evidence: "first backport")
      create(:commit_verdict, patchset_run: run, topic: topic, commit: second, verdict: "modified", evidence: "second backport")
      create(:commit_verdict, patchset_run: create(:patchset_run, topic: topic, created_at: start), topic: topic, commit: master)

      presenter = Lineage::ThreadPresenter.new(topic, ordinals: {})
      linked = Commit.for_topic(topic.id, sources: CommitTopic::SOURCES).to_a
      summary = Topics::CommitSummary.new(linked, credit_sources: Api::V1::CommitPageData::SOURCES)
      shown = presenter.verdicts_for_groups(summary)
      keys = %i[verdict confidence change_level origin source_message_id evidence reviewers_final reviewers_earlier reviewers_none]

      get "/api/v1/topics/#{topic.id}/commits", headers: reader_headers

      expect(data.size).to eq(kinds.size + 1)
      expect(shown.size).to be_between(6, kinds.size)
      data.each do |row|
        expected = shown[row["sha"]]
        expect(row["verdict"]&.except("reviews")).to eq(expected&.slice(*keys)&.stringify_keys), row["sha"]
        expect(row["verdict"]&.fetch("reviews")&.map { |review| review["reviewer"] })
          .to eq(expected && expected[:reviews].map { |review| review["reviewer"] })
      end
      expect(CommitVerdict.where(patchset_run: run).map { |row| Api::V1::CommitLineageData.shown?(row) })
        .to eq(CommitVerdict.where(patchset_run: run).map { |row| presenter.shown_on_thread?(row) })
    end

    it "gives a review without a coverage the coverage none, and leaves out one without a reviewer" do
      row = commit(sha_a)
      stored = [
        { "reviewer" => "Alice", "note" => "no coverage stored" },
        { "reviewer" => "Bob", "coverage" => "", "source" => "llm" },
        { "coverage" => "final", "note" => "nobody" },
        { "reviewer" => nil, "coverage" => "final" },
        { "reviewer" => 5, "coverage" => "final" },
        "not a row",
        { "reviewer" => "Carol", "coverage" => "earlier", "source" => "trailer", "note" => "as usual" }
      ]
      create(:commit_verdict, patchset_run: run, topic: topic, commit: row, reviews: stored)

      get "/api/v1/topics/#{topic.id}/commits", headers: reader_headers

      expect(response).to have_http_status(:ok)
      expect(data.sole["verdict"]["reviews"]).to eq([
        { "reviewer" => "Alice", "coverage" => "none", "source" => nil, "note" => "no coverage stored" },
        { "reviewer" => "Bob", "coverage" => "none", "source" => "llm", "note" => nil },
        { "reviewer" => "Carol", "coverage" => "earlier", "source" => "trailer", "note" => "as usual" }
      ])
    end

    it "gives null verdicts for a thread without a run" do
      commit(sha_a)

      get "/api/v1/topics/#{topic.id}/commits", headers: reader_headers

      expect(data.map { |row| row.values_at("link_source", "verdict") }).to eq([ [ "trailer", nil ] ])
    end

    it "runs the same queries for one entry and for three, and does not write" do
      decorated = lambda do |n|
        row = commit(n.to_s * 40, at: start + n.days, source: n.odd? ? "llm" : "trailer")
        credit(row, "author", "Author #{n}", source: "llm", confidence: 0.9)
        credit(row, "reviewer", "Reviewer #{n}")
        create(:commit_verdict, patchset_run: run, topic: topic, commit: row, reviews: reviews(m1))
      end
      decorated.call(1)
      warm_up
      one = captured_queries { get "/api/v1/topics/#{topic.id}/commits", headers: reader_headers }
      expect(data.size).to eq(1)

      2.times { |i| decorated.call(i + 2) }
      three = captured_queries { get "/api/v1/topics/#{topic.id}/commits", headers: reader_headers }

      expect(data.size).to eq(3)
      expect(data.map { |row| row["verdict"] }).to all(be_present)
      expect(data.map { |row| row["people"].size }).to eq([ 2, 2, 2 ])
      expect(three.size).to eq(one.size)
      expect(three.grep(/\A\s*(INSERT|DELETE)/i)).to be_empty
      expect(three.grep(/\A\s*UPDATE/i).grep_v(/"api_tokens"/)).to be_empty
    end
  end

  describe "patchsets" do
    it "gives each patchset of a thread its step, null where the run has none" do
      lineage_thread(old_step: true)
      late = patchset(at: start + 2.hours)

      get "/api/v1/topics/#{topic.id}/patchsets", headers: reader_headers

      expect(response).to have_http_status(:ok)
      expect(data.map { |row| row["message_id"] }).to eq([ late.id, old_only.id, m2.id, m1.id ])
      expect(data.map { |row| row["lineage"]&.fetch("step_kind") }).to eq([ nil, nil, "rebase", "new_series" ])
      expect(data.map { |row| row["lineage"] }).to eq([
        nil,
        nil,
        { "parent_message_id" => m1.id, "step_kind" => "rebase", "confidence" => 0.85,
          "reason" => "same hunks as [msg:#{m1.id}]" },
        { "parent_message_id" => nil, "step_kind" => "new_series", "confidence" => 1.0, "reason" => "first version" }
      ])
      expect(response.body).not_to include("old reason")
    end

    it "gives null for every patchset of a thread without a finished run" do
      patchset
      create(:patchset_run, topic: topic, status: "failed")

      get "/api/v1/topics/#{topic.id}/patchsets", headers: reader_headers

      expect(data.map { |row| row.fetch("lineage") }).to eq([ nil ])
    end

    it "gives a person's patchsets the step of the current run of each thread" do
      lineage_thread
      other = create(:topic, creator_alias: alice)
      there = patchset(at: start + 1.day, in_topic: other)
      old = create(:patchset_run, topic: other, created_at: start)
      step(there, in_run: old, step_kind: "resend", reason: "old reason")
      current = create(:patchset_run, topic: other, created_at: start + 1.day)
      step(there, in_run: current, step_kind: "major_rework", reason: "new approach")
      bare = patchset(at: start + 2.days, in_topic: create(:topic, creator_alias: alice))

      get "/api/v1/people/alice.a@example.org/patchsets", headers: reader_headers

      expect(data.map { |row| row["message_id"] }).to eq([ bare.id, there.id, m2.id, m1.id ])
      expect(data.map { |row| row["lineage"]&.fetch("step_kind") }).to eq([ nil, "major_rework", "rebase", "new_series" ])
      expect(data.second["lineage"]).to eq("parent_message_id" => nil, "step_kind" => "major_rework", "confidence" => 0.9,
                                           "reason" => "new approach")
    end

    it "runs the same queries for one step and for four, on a thread and over the threads of a person" do
      step(m1)
      warm_up
      thread_one = captured_queries { get "/api/v1/topics/#{topic.id}/patchsets", headers: reader_headers }
      person_one = captured_queries { get "/api/v1/people/alice.a@example.org/patchsets", headers: reader_headers }
      expect(data.map { |row| row["lineage"] }.compact.size).to eq(1)

      step(m2, parent_message: m1, step_kind: "rebase")
      2.times do |i|
        other = create(:topic, creator_alias: alice)
        step(patchset(at: start + (i + 1).days, in_topic: other), in_run: create(:patchset_run, topic: other))
      end
      thread_two = captured_queries { get "/api/v1/topics/#{topic.id}/patchsets", headers: reader_headers }
      expect(data.map { |row| row["lineage"] }).to all(be_present)
      person_four = captured_queries { get "/api/v1/people/alice.a@example.org/patchsets", headers: reader_headers }

      expect(data.size).to eq(4)
      expect(data.map { |row| row["lineage"] }).to all(be_present)
      expect(thread_two.size).to eq(thread_one.size)
      expect(person_four.size).to eq(person_one.size)
      expect(person_four.grep(/"patchset_runs"/).size).to eq(1)
      expect(person_four.grep(/"patchset_lineages"/).size).to eq(1)
      expect((thread_two + person_four).grep(/\A\s*(INSERT|DELETE)/i)).to be_empty
    end
  end

  describe "GET /topics/{id}" do
    it "links to the lineage when the thread has a finished run" do
      run

      get "/api/v1/topics/#{topic.id}", headers: reader_headers

      expect(body["links"].keys).to match_array(%w[messages patchsets commits lineage])
      expect(body["links"]["lineage"]).to end_with("/api/v1/topics/#{topic.id}/lineage")

      get URI(body["links"]["lineage"]).path, headers: reader_headers
      expect(response).to have_http_status(:ok)
    end

    it "has no lineage link without a finished run" do
      create(:patchset_run, topic: topic, status: "queued", finished_at: nil)

      get "/api/v1/topics/#{topic.id}", headers: reader_headers

      expect(body["links"].keys).to match_array(%w[messages patchsets commits])
    end

    it "does not look up runs on a list" do
      run
      warm_up
      list = captured_queries { get "/api/v1/topics", headers: reader_headers }

      expect(list.grep(/"user_features"|"team_features"|"patchset_runs"/)).to be_empty
    end
  end
end
