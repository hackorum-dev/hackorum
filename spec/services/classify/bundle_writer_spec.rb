require "rails_helper"

RSpec.describe Classify::BundleWriter do
  let(:topic) { create(:topic, title: "Add foo option to COPY") }
  let(:dir) { Dir.mktmpdir("classify-bundle") }
  let(:prompt) { File.read(File.join(dir, "prompt.md")) }

  after { FileUtils.rm_rf(dir) }

  def committer_alias(name = "Tom Committer")
    a = create(:alias, name:)
    ContributorMembership.create!(person: a.person, contributor_type: "committer")
    a
  end

  def post(body:, at:, sender: nil)
    attrs = { topic:, body:, created_at: at }
    attrs[:sender] = sender if sender
    create(:message, **attrs)
  end

  it "inlines a small thread with ordinals and flags" do
    first = post(body: "Proposal: COPY ... FOO", at: Time.utc(2026, 3, 1, 10))
    reply = post(body: "On Mon, someone wrote:\n> quoted line\nLooks good, patch attached.", at: Time.utc(2026, 3, 2, 10),
                 sender: committer_alias)
    reply.update_column(:is_patch_submission, true)

    idx = described_class.new(topic:).write(dir)

    expect(idx).to eq("mode" => "inline", "message_count" => 2, "through_message_id" => reply.id, "candidate_group_ids" => [])
    expect(JSON.parse(File.read(File.join(dir, "index.json")))).to eq(idx)
    expect(prompt).to include("### [001] 2026-03-01 #{first.sender_display_alias.name}\n")
    expect(prompt).to include("### [002] 2026-03-02 Tom Committer (committer)(patch)\n")
    expect(prompt).to include("Proposal: COPY ... FOO", "Looks good, patch attached.", "Add foo option to COPY", topic.id.to_s)
    expect(prompt).not_to include("> quoted", "someone wrote")
    expect(prompt).not_to match(/\{\{\w+\}\}/)
    expect(Dir.exist?(File.join(dir, "messages"))).to be(false)
  end

  it "keeps every per-thread value below a fixed instruction prefix" do
    template = File.read(described_class::PROMPT_PATH)
    head = template.index("\n# This thread\n")
    expect(head).to be_present
    expect(template[0, head]).not_to match(/\{\{\w+\}\}/)

    post(body: "hello", at: 1.day.ago)
    described_class.new(topic:).write(dir)
    other_dir = Dir.mktmpdir("classify-bundle")
    other = create(:topic, title: "Something else")
    create(:message, topic: other, body: "hi", created_at: 1.day.ago)
    described_class.new(topic: other).write(other_dir)
    other_prompt = File.read(File.join(other_dir, "prompt.md"))
    expect(prompt[0, head]).to eq(other_prompt[0, head])
    expect(prompt[head..]).to include("Add foo option to COPY", topic.id.to_s)
  ensure
    FileUtils.rm_rf(other_dir) if other_dir
  end

  it "cuts one huge message" do
    post(body: "x" * 50_000, at: 2.days.ago)
    post(body: "short reply", at: 1.day.ago)

    idx = described_class.new(topic:).write(dir)

    expect(idx["mode"]).to eq("inline")
    expect(prompt).to include("[... cut 38000 chars]", "short reply")
    expect(prompt).not_to include("x" * 12_001)
  end

  it "switches to digest above the inline limit" do
    writer = create(:alias, name: "Plain Writer")
    40.times { |i| post(body: "m#{i} " + ("a" * 6_000), at: (100 - i).hours.ago, sender: writer) }
    post(body: "committer verdict", at: 89.5.hours.ago, sender: committer_alias)

    idx = described_class.new(topic:).write(dir)

    expect(idx["mode"]).to eq("digest")
    expect(idx["message_count"]).to eq(41)
    expect(Dir[File.join(dir, "messages/*.txt")].size).to eq(41)
    expect(File.size(File.join(dir, "prompt.md"))).to be < 160_000 + 20_000
    expect(prompt).to include("### [001]", "committer verdict", "messages/NNN.txt", "### [041]")
    expect(prompt).not_to include("### [002]")
    expect(File.read(File.join(dir, "messages/002.txt"))).to include("m1 ", "a" * 6_000)
  end

  it "keeps the digest under the limit when committers wrote most of the thread" do
    sender = committer_alias
    120.times { |i| post(body: "c#{i} " + ("b" * 11_000), at: (200 - i).hours.ago, sender:) }

    idx = described_class.new(topic:).write(dir)

    expect(idx["mode"]).to eq("digest")
    thread = prompt.split("## Thread", 2).last
    expect(thread.size).to be <= described_class::INLINE_CHAR_LIMIT
    expect(prompt).to include("### [001]", "### [120]")
  end

  it "lists facts and the previous result" do
    Classify::Setup.call!
    hackers = create(:mailing_list, identifier: "pgsql-hackers")
    create(:topic_mailing_list, topic:, mailing_list: hackers)
    m = post(body: "patch v1", at: 3.days.ago)
    create(:attachment, :patch_file, message: m)

    cp = create(:commitfest_patch, title: "COPY FOO option", topic: "SQL Commands")
    create(:commitfest_patch_topic, commitfest_patch: cp, topic:)
    create(:commitfest_patch_commitfest, commitfest_patch: cp, status: "Needs review",
                                         commitfest: create(:commitfest, start_date: 4.months.ago))
    create(:commitfest_patch_commitfest, commitfest_patch: cp, status: "Committed",
                                         commitfest: create(:commitfest, start_date: 1.month.ago))

    commit = create(:commit, subject: "Add FOO option to COPY", branches: %w[master])
    backport = create(:commit, subject: "Add FOO option to COPY", branches: %w[REL_17_STABLE],
                               cherry_picked_from_sha: commit.sha)
    create(:commit_topic, commit:, topic:)
    create(:commit_topic, commit: backport, topic:)

    listed = ->(t) { create(:topic_mailing_list, topic: t, mailing_list: hackers) && t }
    other = listed.(create(:topic, title: "Crash in COPY FROM"))
    create(:topic_link, topic:, other_topic: other, kind: "mention", direction: "out")
    fixer = listed.(create(:topic, title: "Fix for COPY"))
    create(:topic_link, topic:, other_topic: fixer, kind: "fixes", direction: "out", ref: backport)
    create(:topic_link, topic:, other_topic: listed.(create(:topic, title: "Earlier")), kind: "fixes", direction: "in", ref: backport)
    committers = create(:topic, title: "pgsql: Add FOO option to COPY")
    create(:topic_mailing_list, topic: committers, mailing_list: create(:mailing_list, identifier: "pgsql-committers"))
    create(:topic_link, topic:, other_topic: committers, kind: "mention", direction: "out")
    Classify::BotNote.new(other).write!(%w[bug])
    group = create(:feature_group, name: "COPY improvements", summary: "Work on COPY")
    create(:feature_group_topic, topic: other, feature_group: group)

    previous = { "kind" => "feature", "size" => "minor", "enhancement" => false, "not_a_bug" => false, "join_linked" => [],
                 "group" => { "id" => group.id, "new_name" => nil, "new_summary" => nil },
                 "feature_name" => "COPY FOO", "evidence" => [ "[001] adds FOO" ], "confidence" => "medium" }

    idx = described_class.new(topic:, previous:).write(dir)

    expect(prompt).to include("pgsql-hackers")
    expect(prompt).to include("COPY FOO option", "SQL Commands", "Committed")
    expect(prompt).not_to include("Needs review")
    expect(prompt).to include("+1/-0", "src/backend/test.c")
    expect(prompt).to include("#{commit.sha[0, 10]} #{commit.committed_at.utc.strftime('%Y-%m-%d')} Add FOO option to COPY")
    expect(prompt).to include("backpatched to REL_17_STABLE")
    expect(prompt).not_to include(backport.sha[0, 10])
    expect(prompt).to include("a commit here refers to its commit", "its commit refers to a commit here")
    expect(prompt).to include("topic #{other.id}: \"Crash in COPY FROM\"")
    expect(prompt).not_to include("pgsql: Add FOO option to COPY")
    expect(prompt).to include("Crash in COPY FROM", "mentions", "tags: bug", "group: COPY improvements")
    expect(prompt).to include("\"kind\": \"feature\"", "\"size\": \"minor\"", "[001] adds FOO")
    expect(prompt).to include("group #{group.id}: COPY improvements (1 thread): Work on COPY")
    expect(prompt).to include("Group #{group.id} in that answer is COPY improvements.")
    expect(idx["candidate_group_ids"]).to eq([ group.id ])
  end

  it "writes a catalog of live groups" do
    post(body: "hello", at: 1.day.ago)
    b = create(:feature_group, name: "Bravo", summary: "two\tlines\nhere")
    a = create(:feature_group, name: "Alpha", summary: nil)
    gone = create(:feature_group, name: "Charlie")
    gone.merge_into!(b)
    create(:feature_group_topic, topic:, feature_group: b)

    described_class.new(topic:).write(dir)

    rows = File.read(File.join(dir, "groups.tsv")).lines(chomp: true).map { |l| l.split("\t", -1) }
    expect(rows).to eq([ %w[id name threads summary], [ a.id.to_s, "Alpha", "0", "" ], [ b.id.to_s, "Bravo", "1", "two lines here" ] ])
  end

  it "labels a membership set by a run on another thread" do
    post(body: "hello", at: 1.day.ago)
    group = create(:feature_group, name: "Bravo")
    other_run = create(:classification_run, topic: create(:topic))
    create(:feature_group_topic, topic:, feature_group: group, source: "llm", classification_run_id: other_run.id)

    described_class.new(topic:).write(dir)

    expect(prompt).to include("(set by a run on a linked thread)")
  end

  it "labels a membership set by its own run as an earlier run" do
    post(body: "hello", at: 1.day.ago)
    group = create(:feature_group, name: "Bravo")
    own_run = create(:classification_run, topic:)
    create(:feature_group_topic, topic:, feature_group: group, source: "llm", classification_run_id: own_run.id)

    described_class.new(topic:).write(dir)

    expect(prompt).to include("(set by an earlier run)")
  end

  it "says when the previous answer's group was merged or deleted" do
    post(body: "hello", at: 1.day.ago)
    gone = create(:feature_group, name: "Old name")
    survivor = create(:feature_group, name: "Survivor")
    gone.merge_into!(survivor)
    answer = ->(id) { { "kind" => "feature", "size" => "minor", "enhancement" => false, "not_a_bug" => false, "join_linked" => [], "group" => { "id" => id } } }

    described_class.new(topic:, previous: answer.(gone.id)).write(dir)
    expect(prompt).to include("Group #{gone.id} in that answer has been merged into group #{survivor.id}, Survivor.")

    described_class.new(topic:, previous: answer.(999_999)).write(dir)
    expect(File.read(File.join(dir, "prompt.md")))
      .to include("Group 999999 in that answer no longer exists; pick another group or none.")
  end

  it "says when there is no previous result and no candidate group" do
    post(body: "hello", at: 1.day.ago)
    described_class.new(topic:).write(dir)

    expect(prompt).to match(/## Previous answer\s+None/)
    expect(prompt).to match(/## Candidate groups\s+None/)
  end

  it "validates a sample answer against the schema" do
    schema = JSONSchemer.schema(described_class::SCHEMA_PATH)
    answer = { "kind" => "feature", "size" => "moderate", "enhancement" => false, "not_a_bug" => false, "join_linked" => [],
               "group" => { "id" => nil, "new_name" => "COPY improvements", "new_summary" => "Options for COPY." },
               "feature_name" => "COPY FOO option", "evidence" => [ "[001] proposes FOO" ], "confidence" => "high" }

    expect(schema.valid?(answer)).to be(true)
    expect(schema.valid?(answer.merge("kind" => "bug", "size" => nil, "group" => { "id" => 3, "new_name" => nil, "new_summary" => nil }))).to be(true)
    expect(schema.valid?(answer.merge("size" => "huge"))).to be(false)
    expect(schema.valid?(answer.merge("evidence" => []))).to be(false)
    expect(schema.valid?(answer.except("group"))).to be(false)
    expect(schema.valid?(answer.merge("extra" => 1))).to be(false)
  end

  it "keeps the schema within structured output rules" do
    check = lambda do |node|
      next unless node.is_a?(Hash)

      if node["type"] == "object" || node["type"]&.include?("object")
        expect(node["additionalProperties"]).to be(false)
        expect(node["required"]).to match_array(node["properties"].keys)
      end
      node.each_value { |v| v.is_a?(Array) ? v.each { |x| check.(x) } : check.(v) }
    end
    check.(JSON.parse(File.read(described_class::SCHEMA_PATH)))
  end

  it "versions the prompt and schema together" do
    expect(described_class.prompt_version).to match(/\A\h{12}\z/)
  end
end
