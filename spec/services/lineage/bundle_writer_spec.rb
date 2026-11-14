require "rails_helper"

RSpec.describe Lineage::BundleWriter do
  WRITER_PATCH = "diff --git a/src/backend/x.c b/src/backend/x.c\n--- a/src/backend/x.c\n+++ b/src/backend/x.c\n@@ -1,1 +1,2 @@\n a\n+b\n"

  def patch_message(topic, at)
    m = create(:message, topic: topic, created_at: at, is_patch_submission: true)
    create(:attachment, message: m, file_name: "0001-x.patch", body: Base64.encode64(WRITER_PATCH))
    m
  end

  let(:topic) { create(:topic) }
  let!(:m1) { patch_message(topic, 2.days.ago) }
  let!(:m2) { patch_message(topic, 1.day.ago) }
  let(:run) { create(:patchset_run, topic: topic, status: "claimed", mode: "trailer") }

  it "writes the database half and returns the ingest index" do
    commit = create(:commit)
    backport = create(:commit, cherry_picked_from_sha: commit.sha, branches: [ "REL_17_STABLE" ])
    create(:commit_person, commit: commit, role: "reviewer", raw_name: "Rev One", source: "parsed")
    boss = create(:person)
    create(:commit_person, commit: commit, role: "committer", raw_name: "Boss", person: boss, source: "parsed")
    create(:commit_person, commit: backport, role: "reviewer", raw_name: "The Boss", person: boss, source: "parsed")
    create(:patch_branch, topic: topic, message: m1, status: "applied", base_sha: "c" * 40)
    linked = create(:commit)
    create(:commit_topic, topic: topic, commit: linked, source: "llm", confidence: 0.9)

    Dir.mktmpdir do |dir|
      cands = [ { commit: commit, origin: "trailer", overlap: nil }, { commit: backport, origin: "trailer", overlap: nil } ]
      index = described_class.new(run: run, topic: topic, candidates: cands, mode: "trailer").call(dir)

      expect(index["mode"]).to eq("trailer")
      expect(index["through_message_id"]).to eq(m2.id)
      expect(index["patchsets"]).to eq([ { "message_id" => m1.id }, { "message_id" => m2.id } ])
      expect(index["patch_mail_ids"]).to eq([ m1.id, m2.id ])
      expect(index["candidates"]).to eq([
        { "sha" => commit.sha, "origin" => "trailer", "backports" => [ backport.sha ], "reviewers" => [ "Rev One", "The Boss" ],
          "committer_reviewers" => [ "The Boss" ], "other_threads" => [] },
        { "sha" => linked.sha, "origin" => "previous", "backports" => [], "reviewers" => [], "committer_reviewers" => [],
          "other_threads" => [] } ])

      disk = JSON.parse(File.read(File.join(dir, "index.json")))
      expect(disk["patchsets"].first["branch"]).to include("status" => "applied", "base_sha" => "c" * 40)
      expect(disk).not_to have_key("repo_path")
      expect(disk["candidates"].first).not_to have_key("diff_available")
      expect(File.exist?(File.join(dir, "patchsets", "001", "0001-x.patch"))).to be(true)
      expect(JSON.parse(File.read(File.join(dir, "pairs.json"))).size).to eq(1)
      expect(File.exist?(File.join(dir, "commit_scores.json"))).to be(false)
      expect(Dir.exist?(File.join(dir, "commits"))).to be(false)
      expect(File.read(File.join(dir, "README.md"))).to include("{{repo_path}}")
      expect(PatchsetPair.where(topic_id: topic.id).count).to eq(1)
    end
  end

  it "adds other threads to trailer candidates" do
    commit = create(:commit)
    other = create(:topic).tap { |t| create(:message, topic: t, is_patch_submission: true) }
    create(:commit_topic, commit: commit, topic: other, source: "trailer")
    Dir.mktmpdir do |dir|
      index = described_class.new(run: run, topic: topic, candidates: [ { commit: commit, origin: "trailer", overlap: nil } ],
                                  mode: "trailer", branches: ->(_) { {} }).call(dir)
      expect(index["candidates"].sole["other_threads"]).to eq([ { "topic_id" => other.id, "verdict" => nil, "source_message_id" => nil } ])
      full = JSON.parse(File.read(File.join(dir, "index.json")))
      expect(full["candidates"].sole["other_threads"].sole).to include("topic_id" => other.id, "patchset_count" => 1)
    end
  end

  it "omits other threads in lineage mode" do
    commit = create(:commit)
    Dir.mktmpdir do |dir|
      index = described_class.new(run: run, topic: topic, candidates: [ { commit: commit, origin: "trailer", overlap: nil } ],
                                  mode: "lineage", branches: ->(_) { {} }).call(dir)
      expect(index["candidates"].sole).not_to have_key("other_threads")
    end
  end

  it "marks recheck candidates" do
    commit = create(:commit)
    base = create(:patchset_run, topic: topic, status: "done", mode: "trailer", through_message: m1, raw_result: { "story" => [ "s" ] })
    Dir.mktmpdir do |dir|
      index = described_class.new(run: run, topic: topic, candidates: [ { commit: commit, origin: "trailer", overlap: nil, recheck: true } ],
                                  mode: "update", base_run: base, branches: ->(_) { {} }).call(dir)
      expect(index["candidates"].sole["recheck"]).to be(true)
      expect(JSON.parse(File.read(File.join(dir, "index.json")))["candidates"].sole["recheck"]).to be(true)
    end
  end

  it "calls the branches lambda when given one" do
    create(:commit_topic, topic: topic, commit: create(:commit), source: "llm", confidence: 0.9)
    Dir.mktmpdir do |dir|
      seen = nil
      branches = ->(patchsets) { seen = patchsets.size; patchsets.to_h { |p| [ p.message.id, { status: "failed" } ] } }
      index = described_class.new(run: run, topic: topic, candidates: [], mode: "lineage", branches: branches).call(dir)
      expect(seen).to eq(2)
      expect(index["candidates"]).to eq([])
      disk = JSON.parse(File.read(File.join(dir, "index.json")))
      expect(disk["patchsets"].map { |p| p["branch"] }).to eq([ { "status" => "failed" }, { "status" => "failed" } ])
    end
  end

  describe "update mode" do
    let(:base) do
      create(:patchset_run, topic: topic, status: "done", mode: "trailer", through_message: m1,
                            raw_result: { "lineage" => [], "verdicts" => [], "story" => [ "old" ] })
    end
    let(:update_run) { create(:patchset_run, topic: topic, status: "claimed", mode: "update") }

    it "marks new patchsets and messages and keeps only new pairs" do
      create(:commit_topic, topic: topic, commit: create(:commit), source: "llm", confidence: 0.9)
      fresh = create(:commit)
      Dir.mktmpdir do |dir|
        cands = [ { commit: fresh, origin: "trailer", overlap: nil } ]
        index = described_class.new(run: update_run, topic: topic, candidates: cands, mode: "update", base_run: base).call(dir)

        expect(index["base_run_id"]).to eq(base.id)
        expect(index["since_message_id"]).to eq(m1.id)
        expect(index["patchsets"]).to eq([ { "message_id" => m1.id, "new" => false }, { "message_id" => m2.id, "new" => true } ])
        expect(index["candidates"].map { |c| c["sha"] }).to eq([ fresh.sha ])

        disk = JSON.parse(File.read(File.join(dir, "index.json")))
        expect(disk["since_message_id"]).to eq(m1.id)
        expect(disk["new_message_ordinals"]).to eq([ 2 ])
        expect(disk["patchsets"].map { |p| p["new"] }).to eq([ false, true ])
        expect(disk["previous"]).to eq(base.raw_result)
        expect(JSON.parse(File.read(File.join(dir, "pairs.json"))).map { |p| p["later_message_id"] }).to eq([ m2.id ])
      end
    end

    it "lists patch mail with no patchset and hides the base's own update answer" do
      bare = create(:message, topic: topic, created_at: 12.hours.ago, is_patch_submission: true)
      base.update!(raw_result: base.raw_result.merge("update" => { "story" => [ "inner" ] }))
      Dir.mktmpdir do |dir|
        index = described_class.new(run: update_run, topic: topic, candidates: [], mode: "update", base_run: base).call(dir)

        expect(index["patch_mail_ids"]).to eq([ m1.id, m2.id, bare.id ])
        expect(index["patchsets"].map { |p| p["message_id"] }).to eq([ m1.id, m2.id ])
        disk = JSON.parse(File.read(File.join(dir, "index.json")))
        expect(disk["previous"]).to eq("lineage" => [], "verdicts" => [], "story" => [ "old" ])
      end
    end

    it "flags late patch mail the base run did not see, whatever its date" do
      base.update!(through_message: m2, bundle_index: { "patchsets" => [ { "message_id" => m1.id }, { "message_id" => m2.id } ] })
      late = patch_message(topic, 3.days.ago)
      Dir.mktmpdir do |dir|
        index = described_class.new(run: update_run, topic: topic, candidates: [], mode: "update", base_run: base).call(dir)

        expect(index["patchsets"]).to eq([ { "message_id" => late.id, "new" => true },
                                           { "message_id" => m1.id, "new" => false }, { "message_id" => m2.id, "new" => false } ])
        disk = JSON.parse(File.read(File.join(dir, "index.json")))
        expect(disk["new_message_ordinals"]).to eq([ 1 ])
        expect(File.read(File.join(dir, "messages", "001.txt"))).to start_with("Message: #1 (id #{late.id})")
        expect(JSON.parse(File.read(File.join(dir, "pairs.json"))).map { |p| p["earlier_message_id"] }).to eq([ late.id, late.id ])
      end
    end

    it "writes update keys when the base has no through message" do
      base.update!(through_message: nil)
      Dir.mktmpdir do |dir|
        index = described_class.new(run: update_run, topic: topic, candidates: [], mode: "update", base_run: base).call(dir)

        expect(index).to include("base_run_id" => base.id, "since_message_id" => nil)
        disk = JSON.parse(File.read(File.join(dir, "index.json")))
        expect(disk).to include("since_message_id" => nil, "new_message_ordinals" => [ 1, 2 ])
        expect(disk["patchsets"].map { |p| p["new"] }).to eq([ true, true ])
      end
    end
  end

  it "adds no update keys in other modes" do
    Dir.mktmpdir do |dir|
      index = described_class.new(run: run, topic: topic, candidates: [], mode: "trailer").call(dir)
      disk = JSON.parse(File.read(File.join(dir, "index.json")))
      expect(index).not_to include("base_run_id", "since_message_id")
      expect(disk).not_to include("since_message_id", "new_message_ordinals")
      expect(disk["patchsets"].first).not_to have_key("new")
    end
  end
end
