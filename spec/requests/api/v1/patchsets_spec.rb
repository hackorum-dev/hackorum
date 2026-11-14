require "rails_helper"

RSpec.describe "API v1 patchsets", type: :request do
  let(:alice) { create(:alias, :with_sent_messages, name: "Alice A", email: "alice.a@example.org") }
  let(:bob) { create(:alias, :with_sent_messages, name: "Bob B", email: "bob@example.org") }
  let(:topic) { create(:topic, creator_alias: alice, title: "Add a feature", slug: "add-feature") }
  let(:start) { Time.zone.parse("2026-03-01 10:00:00") }

  let(:patchset_keys) do
    %w[message_id number url html_url created_at subject sender topic files changed_paths branch download_url lineage]
  end
  let(:attachment_keys) { %w[id message_id file_name content_type byte_size is_patch url content_url] }

  def body
    JSON.parse(response.body)
  end

  def data
    body["data"]
  end

  def ids
    data.map { |row| row["message_id"] }
  end

  def error_code
    body.dig("error", "code")
  end

  def message(at: start, sender: alice, in_topic: topic, **attrs)
    create(:message, topic: in_topic, sender: sender, created_at: at, **attrs)
  end

  def archive_names(row)
    archive = PatchsetArchive.build(message: row, attachment_number: 1)
    names = []
    Zlib::GzipReader.wrap(StringIO.new(archive[:data])) do |gz|
      Gem::Package::TarReader.new(gz) { |tar| tar.each { |entry| names << entry.full_name } }
    end
    names - [ "hackorum.json" ]
  end

  def patchset(files: [ "v1-0001-feature.patch" ], paths: [], **attrs)
    row = message(**attrs)
    files.each do |name|
      create(:attachment, message: row, file_name: name, body: Base64.encode64("not a diff\n" * 3))
    end
    paths.each { |path| create(:patch_submission_file, message: row, path: path) }
    row.update_columns(is_patch_submission: true)
    row
  end

  describe "GET /topics/{id}/patchsets" do
    it "lists the patch messages newest first with the documented row, without a token" do
      first = patchset(subject: "Add a feature", paths: %w[src/b.c src/a.c doc/x.sgml])
      message(at: start + 1.hour, sender: bob)
      second = patchset(at: start + 2.hours, files: %w[v2-0001-feature.patch notes.txt v2-0002-more.diff])
      message(at: start + 3.hours, sender: bob)
      third = patchset(at: start + 4.hours, sender: bob, files: [ "v3.patch" ], paths: [ "src/a.c" ])

      get "/api/v1/topics/#{topic.id}/patchsets"

      expect(response).to have_http_status(:ok)
      expect(response.headers["RateLimit-Limit"]).to be_present
      expect(body.keys).to match_array(%w[data next_cursor])
      expect(body["next_cursor"]).to be_nil
      expect(ids).to eq([ third.id, second.id, first.id ])
      expect(data.map { |row| row["number"] }).to eq([ 5, 3, 1 ])
      expect(data.map { |row| row["changed_paths"] }).to eq([ [ "src/a.c" ], [], %w[doc/x.sgml src/a.c src/b.c] ])
      expect(data.map { |row| row["files"].map { |file| file["file_name"] } })
        .to eq([ [ "v3.patch" ], %w[v2-0001-feature.patch v2-0002-more.diff], [ "v1-0001-feature.patch" ] ])

      row = data.last
      expect(row.keys).to match_array(patchset_keys)
      expect(row).to include("message_id" => first.id, "number" => 1, "subject" => "Add a feature",
                             "created_at" => "2026-03-01T10:00:00.000Z", "branch" => nil)
      expect(row["url"]).to end_with("/api/v1/messages/#{first.id}")
      expect(row["html_url"]).to end_with("/topics/#{topic.id}#message-#{first.id}")
      expect(row["download_url"]).to end_with("/messages/#{first.id}/patchset")
      expect(row["download_url"]).not_to include("/api/")
      expect(row["sender"]).to include("id" => alice.person_id, "name" => "Alice A", "email" => "alice.a@example.org")
      expect(data.first["sender"]).to include("id" => bob.person_id)
      expect(row["topic"].keys).to match_array(%w[id slug title url html_url])
      expect(row["topic"]).to include("id" => topic.id, "slug" => "add-feature", "title" => "Add a feature")
      expect(row["topic"]["url"]).to end_with("/api/v1/topics/#{topic.id}")
      expect(row["topic"]["html_url"]).to end_with("/topics/#{topic.id}")
      file = row["files"].first
      expect(file.keys).to match_array(attachment_keys)
      expect(file).to include("message_id" => first.id, "is_patch" => true, "byte_size" => 33)
    end

    it "lists the files of the download archive, whatever they are called" do
      row = message
      [ [ "patch", "text/plain" ], [ "fix.txt", "text/x-patch" ], [ "notes.txt", "text/plain" ],
        [ "nocfbot-0002-wip.patch", "text/plain" ], [ "old.diff.3", "text/plain" ] ].each do |name, type|
        create(:attachment, message: row, file_name: name, content_type: type,
                            body: Base64.encode64("diff --git a/a b/a\n@@ -1 +1 @@\n"))
      end
      expect(row.reload.is_patch_submission).to be(true)

      get "/api/v1/topics/#{topic.id}/patchsets"

      files = data.first["files"]
      expect(files.map { |file| file["file_name"] }).to eq(%w[patch fix.txt old.diff.3])
      expect(files.map { |file| file["is_patch"] }).to all(be(true))
      expect(files.map { |file| file["file_name"] }).to match_array(archive_names(row))

      get "/api/v1/topics/#{topic.id}/messages"

      expect(data.first["attachments"].to_h { |file| [ file["file_name"], file["is_patch"] ] }).to eq(
        "patch" => true, "fix.txt" => true, "notes.txt" => false, "nocfbot-0002-wip.patch" => false,
        "old.diff.3" => true
      )
    end

    it "leaves out a message whose attachments are not patches" do
      shown = patchset
      plain = message(at: start + 1.hour)
      create(:attachment, message: plain, file_name: "notes.txt", content_type: "text/plain",
                          body: Base64.encode64("see above\n"))
      hidden = message(at: start + 2.hours)
      create(:attachment, message: hidden, file_name: "nocfbot-0001-wip.patch")

      get "/api/v1/topics/#{topic.id}/patchsets"

      expect(ids).to eq([ shown.id ])
    end

    it "shows the branch of a message, and never a lineage-only one" do
      built = patchset
      internal = patchset(at: start + 1.hour)
      branch = create(:patch_branch, topic: topic, message: built, branch_name: "t#{topic.id}_1",
                                     status: "applied", ci_status: "success", pushed_at: start + 1.hour)
      create(:patch_branch, topic: topic, message: internal, branch_name: "t#{topic.id}_2", lineage_only: true)

      get "/api/v1/topics/#{topic.id}/patchsets"

      expect(ids).to eq([ internal.id, built.id ])
      expect(data.first["branch"]).to be_nil
      expect(data.last["branch"].keys).to match_array(%w[id branch_name status ci_status pushed_at url])
      expect(data.last["branch"]).to include("id" => branch.id, "branch_name" => "t#{topic.id}_1",
                                             "status" => "applied", "ci_status" => "success",
                                             "pushed_at" => "2026-03-01T11:00:00.000Z")
      expect(data.last["branch"]["url"]).to end_with("/api/v1/branches/#{branch.id}")
      expect(response.body).not_to include("t#{topic.id}_2")
    end

    it "shows a branch that was never pushed, with a null pushed_at" do
      failed = patchset
      branch = create(:patch_branch, topic: topic, message: failed, branch_name: "t#{topic.id}_1",
                                     status: "failed", failure_stage: "apply", on_master: false)

      get "/api/v1/topics/#{topic.id}/patchsets"

      expect(data.first["branch"]).to include("id" => branch.id, "status" => "failed", "ci_status" => nil,
                                              "pushed_at" => nil)
    end

    it "finds the topic by slug, answers an unknown one with 404 and an empty one with no rows" do
      message

      get "/api/v1/topics/add-feature/patchsets"
      expect(response).to have_http_status(:ok)
      expect(body).to eq("data" => [], "next_cursor" => nil)

      get "/api/v1/topics/nope/patchsets"
      expect(response).to have_http_status(:not_found)
      expect(error_code).to eq("not_found")
    end

    it "redirects a merged topic and keeps the parameters" do
      source = create(:topic, creator_alias: alice, merged_into_topic_id: topic.id)

      get "/api/v1/topics/#{source.id}/patchsets?limit=2"

      expect(response).to have_http_status(:moved_permanently)
      expect(response.headers["Location"]).to end_with("/api/v1/topics/#{topic.id}/patchsets?limit=2")
    end

    it "pages through ties and rejects a bad limit and cursor" do
      tied = Array.new(3) { patchset(at: start + 1.hour) }
      oldest = patchset(at: start)

      seen = []
      cursor = nil
      2.times do
        get "/api/v1/topics/#{topic.id}/patchsets", params: { limit: 2, cursor: cursor }.compact
        expect(response).to have_http_status(:ok)
        seen.concat(data.map { |row| [ row["message_id"], row["number"] ] })
        cursor = body["next_cursor"]
      end

      expect(cursor).to be_nil
      expect(seen).to eq([ [ tied[2].id, 4 ], [ tied[1].id, 3 ], [ tied[0].id, 2 ], [ oldest.id, 1 ] ])

      get "/api/v1/topics/#{topic.id}/patchsets", params: { limit: 0 }
      expect(response).to have_http_status(:bad_request)
      expect(error_code).to eq("invalid_limit")

      get "/api/v1/topics/#{topic.id}/patchsets", params: { cursor: "nope" }
      expect(response).to have_http_status(:bad_request)
      expect(error_code).to eq("invalid_cursor")
    end

    it "runs the same queries for one row and for three" do
      decorated = lambda do |at|
        row = patchset(at: at, sender: create(:alias, :with_sent_messages), paths: %w[a b],
                       files: %w[x.patch y.patch])
        create(:patch_branch, topic: topic, message: row)
      end
      decorated.call(start)
      one = captured_queries { get "/api/v1/topics/#{topic.id}/patchsets" }
      expect(data.size).to eq(1)

      2.times { |i| decorated.call(start + (i + 1).hours) }
      three = captured_queries { get "/api/v1/topics/#{topic.id}/patchsets" }

      expect(data.size).to eq(3)
      expect(data.map { |row| row["branch"] }).to all(be_present)
      expect(three.size).to eq(one.size)
    end

    it "does not write and never reads a body" do
      patchset(paths: [ "a" ])

      queries = captured_queries { get "/api/v1/topics/#{topic.id}/patchsets" }

      expect(queries.grep(/\A\s*(INSERT|UPDATE|DELETE)/i)).to be_empty
      from_messages = queries.grep(/FROM "messages"/)
      expect(from_messages).not_to be_empty
      expect(from_messages.grep(/"messages"\.\*|"messages"\."body"|messages\.body/)).to be_empty
      on_attachments = queries.grep(/\battachments\b/i)
      expect(on_attachments.size).to eq(1)
      expect(on_attachments.grep(/\*|body|decode/i)).to be_empty
    end
  end

  describe "GET /people/{email}/patchsets" do
    it "lists the person's patch messages over topics, newest first, with thread numbers" do
      other = create(:topic, creator_alias: bob, title: "Other thread")
      message(sender: bob)
      mine = patchset(at: start + 1.hour, paths: [ "src/a.c" ])
      patchset(at: start + 2.hours, sender: bob)
      message(at: start + 3.hours, in_topic: other, sender: bob)
      message(at: start + 4.hours, in_topic: other)
      elsewhere = patchset(at: start + 5.hours, in_topic: other, files: [ "fix.diff" ])
      branch = create(:patch_branch, topic: other, message: elsewhere, branch_name: "t#{other.id}_3")

      get "/api/v1/people/alice.a@example.org/patchsets"

      expect(response).to have_http_status(:ok)
      expect(body["next_cursor"]).to be_nil
      expect(ids).to eq([ elsewhere.id, mine.id ])
      expect(data.first.keys).to match_array(patchset_keys)
      expect(data.map { |row| row["number"] }).to eq([ 3, 2 ])
      expect(data.map { |row| row["topic"]["id"] }).to eq([ other.id, topic.id ])
      expect(data.first["topic"]).to include("title" => "Other thread", "slug" => nil)
      expect(data.first["branch"]).to include("id" => branch.id, "branch_name" => "t#{other.id}_3")
      expect(data.first["files"].map { |file| file["file_name"] }).to eq([ "fix.diff" ])
      expect(data.last["changed_paths"]).to eq([ "src/a.c" ])
      expect(data.map { |row| row["sender"]["id"] }).to eq([ alice.person_id ] * 2)
    end

    it "leaves out merged and hidden-list topics" do
      shown = patchset
      patchset(in_topic: create(:topic, creator_alias: alice, hidden_by_default: true))
      patchset(in_topic: create(:topic, creator_alias: alice, merged_into_topic_id: topic.id))

      get "/api/v1/people/alice.a@example.org/patchsets"

      expect(ids).to eq([ shown.id ])
    end

    it "answers an unknown email and a NUL with 404, and takes the email in any case" do
      patchset

      get "/api/v1/people/nobody@example.org/patchsets"
      expect(response).to have_http_status(:not_found)
      expect(error_code).to eq("not_found")

      get "/api/v1/people/a%00b/patchsets"
      expect(response).to have_http_status(:not_found)

      get "/api/v1/people/ALICE.A%40example.org/patchsets"
      expect(response).to have_http_status(:ok)
      expect(data.size).to eq(1)
    end

    it "pages" do
      rows = Array.new(3) { |i| patchset(at: start + i.hours) }

      get "/api/v1/people/alice.a@example.org/patchsets", params: { limit: 2 }
      expect(ids).to eq([ rows[2].id, rows[1].id ])

      get "/api/v1/people/alice.a@example.org/patchsets", params: { limit: 2, cursor: body["next_cursor"] }
      expect(ids).to eq([ rows[0].id ])
      expect(body["next_cursor"]).to be_nil
    end

    it "rejects a bad limit and cursor" do
      patchset

      get "/api/v1/people/alice.a@example.org/patchsets", params: { limit: 0 }
      expect(response).to have_http_status(:bad_request)
      expect(error_code).to eq("invalid_limit")

      get "/api/v1/people/alice.a@example.org/patchsets", params: { cursor: "nope" }
      expect(response).to have_http_status(:bad_request)
      expect(error_code).to eq("invalid_cursor")
    end

    it "runs the same queries for one row and for three, and does not write" do
      decorated = lambda do |at|
        thread = create(:topic, creator_alias: bob)
        message(in_topic: thread, sender: bob)
        row = patchset(at: at, in_topic: thread, paths: %w[a b], files: %w[x.patch y.patch])
        create(:patch_branch, topic: thread, message: row)
      end
      decorated.call(start)
      one = captured_queries { get "/api/v1/people/alice.a@example.org/patchsets" }
      expect(data.size).to eq(1)

      2.times { |i| decorated.call(start + (i + 1).hours) }
      three = captured_queries { get "/api/v1/people/alice.a@example.org/patchsets" }

      expect(data.size).to eq(3)
      expect(data.map { |row| row["number"] }).to eq([ 2, 2, 2 ])
      expect(three.size).to eq(one.size)
      expect(three.grep(/\A\s*(INSERT|UPDATE|DELETE)/i)).to be_empty
      expect(three.grep(/"messages"\.\*|"messages"\."body"|messages\.body/)).to be_empty
      expect(three.grep(/\battachments\b/i).grep(/\*|body|decode/i)).to be_empty
    end
  end
end
