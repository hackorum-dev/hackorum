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
      expect(index["candidates"]).to eq([
        { "sha" => commit.sha, "origin" => "trailer", "backports" => [ backport.sha ], "reviewers" => [ "Rev One", "The Boss" ],
          "committer_reviewers" => [ "The Boss" ] },
        { "sha" => linked.sha, "origin" => "previous", "backports" => [], "reviewers" => [], "committer_reviewers" => [] } ])

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
end
