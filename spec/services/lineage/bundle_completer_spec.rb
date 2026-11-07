require "rails_helper"

RSpec.describe Lineage::BundleCompleter do
  COMPLETER_PATCH = "diff --git a/src/backend/x.c b/src/backend/x.c\n--- a/src/backend/x.c\n+++ b/src/backend/x.c\n@@ -1,1 +1,2 @@\n a\n+int x;\n"

  def write_bundle(dir, candidates:)
    FileUtils.mkdir_p(File.join(dir, "patchsets", "002"))
    File.write(File.join(dir, "patchsets", "002", "0001-x.patch"), COMPLETER_PATCH)
    index = { "topic" => { "id" => 1 }, "mode" => "full",
              "patchsets" => [ { "ordinal" => 2, "message_id" => 20, "dir" => "patchsets/002",
                                 "files" => [ "0001-x.patch" ], "parse_error" => nil },
                               { "ordinal" => 3, "message_id" => 30, "dir" => "patchsets/003",
                                 "files" => [], "parse_error" => "Boom" } ],
              "candidates" => candidates }
    File.write(File.join(dir, "index.json"), JSON.pretty_generate(index))
    File.write(File.join(dir, "README.md"), "checkout at `{{repo_path}}`\n")
  end

  it "writes commit diffs, scores and the repo path" do
    Dir.mktmpdir do |root|
      repo = File.join(root, "repo")
      sha = GitFixtureRepo.new(repo).commit(subject: "Add x", files: { "src/backend/x.c" => "a\nint x;\n" })
      dir = File.join(root, "job")
      write_bundle(dir, candidates: [ { "sha" => sha, "origin" => "trailer" } ])

      described_class.new(repo_path: repo).call(dir)

      index = JSON.parse(File.read(File.join(dir, "index.json")))
      expect(index["repo_path"]).to eq(repo)
      expect(index["candidates"].map { |c| c["diff_available"] }).to eq([ true ])
      expect(File.read(File.join(dir, "commits", sha, "message.txt"))).to start_with("Add x")
      expect(File.read(File.join(dir, "commits", sha, "diff.patch"))).to include("+int x;")

      scores = JSON.parse(File.read(File.join(dir, "commit_scores.json")))
      expect(scores.size).to eq(2)
      good = scores.find { |s| s["sha"] == sha && s["message_id"] == 20 }
      expect(good["ordinal"]).to eq(2)
      expect(good["metrics"]["file_jaccard"]).to eq(1.0)
      expect(scores.find { |s| s["sha"] == sha && s["message_id"] == 30 }["metrics"]).to eq("unparsed" => true)
      expect(File.read(File.join(dir, "README.md"))).to eq("checkout at `#{repo}`\n")
    end
  end

  it "is a no-op apart from the repo path without candidates" do
    Dir.mktmpdir do |root|
      repo = File.join(root, "repo")
      GitFixtureRepo.new(repo).commit(subject: "x")
      dir = File.join(root, "job")
      write_bundle(dir, candidates: [])

      described_class.new(repo_path: repo).call(dir)

      expect(JSON.parse(File.read(File.join(dir, "commit_scores.json")))).to eq([])
      expect(Dir.exist?(File.join(dir, "commits"))).to be(false)
      expect(File.read(File.join(dir, "README.md"))).to include(repo)
    end
  end

  it "fetches a candidate missing from the checkout" do
    Dir.mktmpdir do |root|
      upstream = GitFixtureRepo.new(File.join(root, "upstream"))
      upstream.commit(subject: "base")
      repo = upstream.clone_to(File.join(root, "repo"))
      sha = upstream.commit(subject: "Add x", files: { "src/backend/x.c" => "a\nint x;\n" })
      dir = File.join(root, "job")
      write_bundle(dir, candidates: [ { "sha" => sha, "origin" => "trailer" } ])

      described_class.new(repo_path: repo).call(dir)

      index = JSON.parse(File.read(File.join(dir, "index.json")))
      expect(index["candidates"].first["diff_available"]).to be(true)
      expect(File.read(File.join(dir, "commits", sha, "diff.patch"))).to include("+int x;")
    end
  end

  it "raises when a candidate is still missing after the fetch" do
    Dir.mktmpdir do |root|
      upstream = GitFixtureRepo.new(File.join(root, "upstream"))
      upstream.commit(subject: "base")
      repo = upstream.clone_to(File.join(root, "repo"))
      dir = File.join(root, "job")
      write_bundle(dir, candidates: [ { "sha" => "0" * 40, "origin" => "trailer" } ])

      expect { described_class.new(repo_path: repo).call(dir) }
        .to raise_error(described_class::MissingCommits, /#{"0" * 40}/)
      expect(File.exist?(File.join(dir, "commit_scores.json"))).to be(false)
    end
  end
end
