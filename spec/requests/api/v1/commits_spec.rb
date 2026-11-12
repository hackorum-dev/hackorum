require "rails_helper"

RSpec.describe "API v1 topic commits", type: :request do
  let(:alice) { create(:alias, :with_sent_messages, name: "Alice A", email: "alice.a@example.org") }
  let(:topic) { create(:topic, creator_alias: alice, title: "Add a feature", slug: "add-feature") }
  let(:start) { Time.zone.parse("2026-03-01 10:00:00") }
  let(:entry_keys) { %w[sha subject committed_at committer_name url branches people] }

  def body
    JSON.parse(response.body)
  end

  def data
    body["data"]
  end

  def shas
    data.map { |row| row["sha"] }
  end

  def link(commit, in_topic: topic, **attrs)
    create(:commit_topic, commit: commit, topic: in_topic, **attrs)
    commit
  end

  def commit(sha, at: start, **attrs)
    link(create(:commit, sha: sha, committed_at: at, **attrs))
  end

  def credit(row, role, name, person: nil, **attrs)
    row.commit_people.create!(role: role, raw_name: name, raw_email: "#{name.to_s.parameterize}@example.com",
                              person: person, **attrs)
  end

  def person(name, email)
    create(:alias, :with_sent_messages, name: name, email: email).person
  end

  def people(row)
    row["people"].map { |entry| [ entry["role"], entry["name"] ] }
  end

  describe "GET /topics/{id}/commits" do
    it "gives a change and its backport as one entry, newest first, without a token" do
      commit("aaa1", subject: "Older change", committer_name: "Tom Lane", branches: [ "master" ])
      commit("bbb2", at: start + 1.day, subject: "Shared change", committer_name: "Alvaro Herrera",
                     branches: [ "master" ])
      commit("ccc3", at: start + 2.days, subject: "Shared change", cherry_picked_from_sha: "bbb2",
                     branches: [ "REL_18_STABLE" ], released_in: "18.5")

      get "/api/v1/topics/#{topic.id}/commits"

      expect(response).to have_http_status(:ok)
      expect(response.headers["RateLimit-Limit"]).to be_present
      expect(body.keys).to match_array(%w[data next_cursor])
      expect(body["next_cursor"]).to be_nil
      expect(shas).to eq(%w[bbb2 aaa1])

      row = data.first
      expect(row.keys).to match_array(entry_keys)
      expect(row).to include("sha" => "bbb2", "subject" => "Shared change", "committer_name" => "Alvaro Herrera",
                             "committed_at" => "2026-03-02T10:00:00.000Z", "people" => [],
                             "url" => "https://github.com/postgres/postgres/commit/bbb2")
      expect(row["branches"]).to eq([
        { "branch" => "master", "version" => "devel", "released_in" => nil },
        { "branch" => "REL_18_STABLE", "version" => "18", "released_in" => "18.5" }
      ])
      expect(data.last["branches"]).to eq([ { "branch" => "master", "version" => "devel", "released_in" => nil } ])
    end

    it "credits each person once per role over the group, in display order" do
      tom = person("Tom Lane", "tgl@example.org")
      master = commit("aaa1")
      backport = commit("bbb2", at: start + 1.hour, cherry_picked_from_sha: "aaa1", branches: [ "REL_18_STABLE" ])
      [ master, backport ].each do |row|
        credit(row, "committer", "Tom Lane", person: tom)
        credit(row, "reviewer", "Zed Reviewer")
        credit(row, "author", "Alexander Lakhin")
        credit(row, "reported_by", "buildfarm member koel")
      end
      credit(master, "reviewer", "Tom Lane", person: tom, source: "committer")
      credit(backport, "reviewer", "Tom Lane", person: tom)
      credit(backport, "tested_by", "tom lane")
      credit(backport, "co_author", "Bea Coauthor")

      get "/api/v1/topics/#{topic.id}/commits"

      expect(shas).to eq([ "aaa1" ])
      expect(people(data.first)).to eq([
        [ "author", "Alexander Lakhin" ], [ "reviewer", "Tom Lane" ], [ "reviewer", "Zed Reviewer" ],
        [ "tested_by", "tom lane" ], [ "reported_by", "buildfarm member koel" ], [ "co_author", "Bea Coauthor" ],
        [ "committer", "Tom Lane" ]
      ])
      entry = data.first["people"].find { |row| row["role"] == "reviewer" && row["name"] == "Tom Lane" }
      expect(entry.keys).to match_array(%w[role name person])
      expect(entry["person"].keys).to match_array(%w[id name email url html_url])
      expect(entry["person"]).to include("id" => tom.id, "name" => "Tom Lane", "email" => "tgl@example.org")
      unresolved = data.first["people"].first
      expect(unresolved).to eq("role" => "author", "name" => "Alexander Lakhin", "person" => nil)
      expect(response.body).not_to include("alexander-lakhin@example.com")
    end

    it "names a resolved person as the site does, and folds the same name without a person into it" do
      tom = person("Tom Lane", "tgl@example.org")
      row = commit("aaa1")
      credit(row, "reviewer", "T. Lane", person: tom)
      credit(row, "reviewer", "Tom Lane")
      credit(row, "author", "Tom Lane")

      get "/api/v1/topics/#{topic.id}/commits"

      expect(people(data.first)).to eq([ [ "author", "Tom Lane" ], [ "reviewer", "Tom Lane" ] ])
      expect(data.first["people"].map { |entry| entry["person"]&.fetch("id") }).to eq([ nil, tom.id ])
    end

    it "leaves out llm links and llm credits, also for a user with another feature" do
      user = create(:user)
      create(:user_feature, user: user, feature: "email_sending")
      shown = commit("aaa1")
      credit(shown, "author", "Trailer Author")
      credit(shown, "reviewer", "Guessed Reviewer", source: "llm", confidence: 0.9)
      guessed = link(create(:commit, sha: "bbb2", subject: "Guessed commit"), source: "llm", confidence: 0.8)
      credit(guessed, "author", "Other Author")

      get "/api/v1/topics/#{topic.id}/commits",
          headers: { "Authorization" => "Bearer #{ApiToken.issue!(user: user, name: "laptop").last}" }

      expect(response).to have_http_status(:ok)
      expect(shas).to eq([ "aaa1" ])
      expect(people(data.first)).to eq([ [ "author", "Trailer Author" ] ])
      expect(response.body).not_to include("Guessed", "Other Author", "verdict", "llm")
    end

    it "lists the committer as reviewer only on a commit whose message names the author" do
      tom = person("Tom Lane", "tgl@example.org")
      guessed = commit("aaa1", at: start + 2.hours)
      credit(guessed, "committer", "Tom Lane", person: tom)
      credit(guessed, "author", "Guessed Author", source: "llm", confidence: 0.9)
      credit(guessed, "reviewer", "Tom Lane", person: tom, source: "committer")
      named = commit("bbb2", at: start + 1.hour)
      credit(named, "committer", "Tom Lane", person: tom)
      credit(named, "co_author", "Named Coauthor")
      credit(named, "reviewer", "Tom Lane", person: tom, source: "committer")
      master = commit("ccc3")
      backport = commit("ddd4", cherry_picked_from_sha: "ccc3", branches: [ "REL_18_STABLE" ])
      credit(master, "author", "Named Author")
      credit(backport, "author", "Guessed Author", source: "llm", confidence: 0.9)
      [ master, backport ].each { |row| credit(row, "reviewer", "Tom Lane", person: tom, source: "committer") }

      get "/api/v1/topics/#{topic.id}/commits"

      expect(shas).to eq(%w[aaa1 bbb2 ccc3])
      expect(data.map { |row| people(row) }).to eq([
        [ [ "committer", "Tom Lane" ] ],
        [ [ "reviewer", "Tom Lane" ], [ "co_author", "Named Coauthor" ], [ "committer", "Tom Lane" ] ],
        [ [ "author", "Named Author" ], [ "reviewer", "Tom Lane" ] ]
      ])
      expect(response.body).not_to include("Guessed")
    end

    it "names a credit without a raw name by its person and skips one that has neither" do
      tom = person("Tom Lane", "tgl@example.org")
      row = commit("aaa1")
      credit(row, "author", nil, person: tom, raw_email: "tgl@sss.example.com")
      credit(row, "reviewer", nil, raw_email: "nameless@example.com")
      credit(row, "reviewer", " ", raw_email: "blank@example.com")

      get "/api/v1/topics/#{topic.id}/commits"

      expect(response).to have_http_status(:ok)
      expect(people(data.first)).to eq([ [ "author", "Tom Lane" ] ])
      expect(data.first["people"].first["person"]).to include("id" => tom.id)
      expect(response.body).not_to include("nameless", "blank@", "sss.example.com")
    end

    it "merges rows of one address whatever the case, with and without a person" do
      tom = person("Tom Lane", "tgl@example.org")
      master = commit("aaa1")
      backport = commit("bbb2", cherry_picked_from_sha: "aaa1", branches: [ "REL_18_STABLE" ])
      credit(master, "reviewer", "Thomas L.", person: tom, raw_email: "tgl@sss.example.com")
      credit(backport, "reviewer", "Tommy", raw_email: "TGL@SSS.Example.com")
      credit(master, "author", "A. Author", raw_email: "Author@Example.com")
      credit(backport, "author", "Ann Author", raw_email: "author@example.com")
      credit(backport, "author", "Other Author", raw_email: "other@example.com")

      get "/api/v1/topics/#{topic.id}/commits"

      expect(people(data.first)).to eq([ [ "author", "A. Author" ], [ "author", "Other Author" ], [ "reviewer", "Tom Lane" ] ])
      expect(data.first["people"].map { |entry| entry["person"]&.fetch("id") }).to eq([ nil, nil, tom.id ])
    end

    it "keeps a name apart that two resolved people have" do
      first = person("Tom Lane", "tgl@example.org")
      second = person("Tom Lane", "tom@example.net")
      row = commit("aaa1")
      credit(row, "reviewer", "Tom Lane", person: first)
      credit(row, "reviewer", "Tom Lane", person: second)
      2.times { |i| credit(row, "reviewer", "tom lane", raw_email: "loose#{i}@example.com") }
      credit(row, "author", "Tom Lane", person: first)
      credit(row, "author", "Tom Lane", raw_email: "loose@example.com")

      get "/api/v1/topics/#{topic.id}/commits"

      entries = data.first["people"]
      expect(entries.map { |entry| [ entry["role"], entry["name"], entry["person"]&.fetch("id") ] }).to eq([
        [ "author", "Tom Lane", first.id ],
        [ "reviewer", "tom lane", nil ], [ "reviewer", "Tom Lane", first.id ], [ "reviewer", "Tom Lane", second.id ]
      ])
    end

    it "shows a backport whose master commit is not linked to the topic by itself" do
      link(create(:commit, sha: "aaa1", subject: "On master", branches: [ "master" ]),
           in_topic: create(:topic, creator_alias: alice))
      commit("bbb2", subject: "Backport 17", cherry_picked_from_sha: "aaa1", branches: [ "REL_17_STABLE" ],
                     committer_name: "Tom Lane", at: start + 1.hour)
      newer = commit("ccc3", subject: "Backport 18", cherry_picked_from_sha: "aaa1", branches: [ "REL_18_STABLE" ],
                             at: start + 2.hours)
      credit(newer, "author", "Named Author")

      get "/api/v1/topics/#{topic.id}/commits"

      expect(data.size).to eq(1)
      expect(data.first).to include("sha" => "ccc3", "subject" => "Backport 18")
      expect(data.first["branches"].map { |row| row["branch"] }).to eq(%w[REL_18_STABLE REL_17_STABLE])
      expect(people(data.first)).to eq([ [ "author", "Named Author" ] ])
      expect(response.body).not_to include("On master")
    end

    it "orders entries of the same time by sha" do
      %w[ccc3 aaa1 ddd4 bbb2].each { |sha| commit(sha) }
      commit("eee5", at: start + 1.hour)

      2.times do
        get "/api/v1/topics/#{topic.id}/commits"
        expect(shas).to eq(%w[eee5 aaa1 bbb2 ccc3 ddd4])
      end
    end

    it "finds the topic by slug, answers an unknown one with 404 and one without commits with no rows" do
      topic
      link(create(:commit), in_topic: create(:topic, creator_alias: alice))

      get "/api/v1/topics/add-feature/commits"
      expect(response).to have_http_status(:ok)
      expect(body).to eq("data" => [], "next_cursor" => nil)

      get "/api/v1/topics/nope/commits"
      expect(response).to have_http_status(:not_found)
      expect(body.dig("error", "code")).to eq("not_found")
    end

    it "redirects a merged topic" do
      source = create(:topic, creator_alias: alice, merged_into_topic_id: topic.id)

      get "/api/v1/topics/#{source.id}/commits"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers["Location"]).to end_with("/api/v1/topics/#{topic.id}/commits")
    end

    it "runs the same queries for one entry and for three, does not write and never reads a body" do
      decorated = lambda do |n|
        master = commit("aaa#{n}", at: start + n.days)
        backport = commit("bbb#{n}", at: start + n.days + 1.hour, cherry_picked_from_sha: "aaa#{n}",
                                     branches: [ "REL_18_STABLE" ])
        author = person("Author #{n}", "author#{n}@example.org")
        [ master, backport ].each do |row|
          credit(row, "author", "Author #{n}", person: author)
          credit(row, "reviewer", "Reviewer #{n}")
        end
      end
      decorated.call(1)
      one = captured_queries { get "/api/v1/topics/#{topic.id}/commits" }
      expect(data.size).to eq(1)

      2.times { |i| decorated.call(i + 2) }
      three = captured_queries { get "/api/v1/topics/#{topic.id}/commits" }

      expect(data.size).to eq(3)
      expect(data.map { |row| row["people"].size }).to eq([ 2, 2, 2 ])
      expect(data.map { |row| row["people"].first["person"] }).to all(be_present)
      expect(three.size).to eq(one.size)
      expect(three.grep(/\A\s*(INSERT|UPDATE|DELETE)/i)).to be_empty
      from_commits = three.grep(/FROM "commits"/)
      expect(from_commits.size).to eq(1)
      expect(from_commits.grep(/"commits"\.\*|body/)).to be_empty
      expect(three.grep(/"commit_people"/).size).to eq(1)
    end

    it "is where the links of the topic detail point, like the messages and the patchsets" do
      commit("aaa1")
      create(:message, topic: topic, sender: alice)

      get "/api/v1/topics/#{topic.id}"
      links = body["links"]

      %w[commits messages patchsets].each do |name|
        get URI(links.fetch(name)).path
        expect(response).to have_http_status(:ok), name
        expect(body["data"]).to be_an(Array)
      end
      get URI(links["commits"]).path
      expect(shas).to eq([ "aaa1" ])
    end
  end
end
