require "rails_helper"

RSpec.describe Lineage::JobBundle do
  it "writes the job directory" do
    topic = create(:topic, title: "Row pattern recognition")
    m0 = create(:message, topic: topic, created_at: 3.days.ago, body: "Hi all,\n\nfirst idea.\n")
    m1 = create(:message, topic: topic, created_at: 2.days.ago, is_patch_submission: true,
                body: "On Mon, X wrote:\n> first idea.\nHere is v1.\n")
    commit = create(:commit, sha: "a" * 40)
    backport = create(:commit, sha: "b" * 40, cherry_picked_from_sha: "a" * 40, branches: [ "REL_17_STABLE" ])
    run = create(:patchset_run, topic: topic, status: "running")

    Dir.mktmpdir do |dir|
      sets_dir = File.join(dir, "patchsets")
      FileUtils.mkdir_p(File.join(sets_dir, "002"))
      patchset = Lineage::PatchsetEnumerator::Patchset.new(
        message: m1, ordinal: 2, dir: File.join(sets_dir, "002"), files: [ "0001-x.patch" ],
        parsed: Lineage::DiffParser::Result.new(files: [], subjects: [ "x" ]), parse_error: nil, nocfbot: false)
      entry = Lineage::CommitDiff::Entry.new(commit: commit, available: true, message_text: "Add x\n",
                                             diff_text: "diff --git a/x b/x\n", parsed: nil)

      described_class.new(run: run, topic: topic, patchsets: [ patchset ],
                          candidates: [ { entry: entry, origin: "trailer", overlap: nil,
                                          backports: [ backport ], reviewers: [ "Some Reviewer" ] } ],
                          pairs: [], commit_scores: [], branches: { m1.id => { status: "applied" } },
                          previous: nil, repo_path: "/repo", mode: "trailer").write(dir)

      index = JSON.parse(File.read(File.join(dir, "index.json")))
      expect(index["topic"]["id"]).to eq(topic.id)
      expect(index["patchsets"].first).to include("message_id" => m1.id, "ordinal" => 2, "dir" => "patchsets/002")
      expect(index["patchsets"].first["branch"]).to eq({ "status" => "applied" })
      expect(index["candidates"].first).to include("sha" => "a" * 40, "origin" => "trailer",
                                                   "backports" => [ "b" * 40 ], "reviewers" => [ "Some Reviewer" ])
      expect(index["mode"]).to eq("trailer")
      expect(index["through_message_id"]).to eq(m1.id)

      msg2 = File.read(File.join(dir, "messages", "002.txt"))
      expect(msg2).to include("Patchset: patchsets/002")
      expect(msg2).to include("Here is v1.")
      expect(msg2).not_to include("> first idea")
      expect(msg2).not_to include("wrote:")
      expect(File.read(File.join(dir, "commits", "a" * 40, "message.txt"))).to eq("Add x\n")
      expect(JSON.parse(File.read(File.join(dir, "pairs.json")))).to eq([])
      expect(JSON.parse(File.read(File.join(dir, "commit_scores.json")))).to eq([])
      expect(index).not_to include("pairs", "commit_scores")
      readme = File.read(File.join(dir, "README.md"))
      expect(readme).to include("Row pattern recognition")
      expect(readme).to include("/repo")
      expect(described_class.prompt_version).to match(/\A[0-9a-f]{12}\z/)
    end
  end

  it "strips gmail attributions and original message tails" do
    topic = create(:topic)
    create(:message, topic: topic, created_at: 2.days.ago,
           body: "Reply.\nOn Tue, Jan 1, 2025 at 10:00 AM Some Body <s@example.com>\nwrote:\n> q\nKeep.\n-----Original Message-----\nold stuff\n")
    run = create(:patchset_run, topic: topic, status: "running")
    Dir.mktmpdir do |dir|
      described_class.new(run: run, topic: topic, patchsets: [], candidates: [], pairs: [], commit_scores: [],
                          branches: {}, previous: nil, repo_path: "/repo", mode: "full").write(dir)
      text = File.read(File.join(dir, "messages", "001.txt"))
      expect(text).to include("Reply.", "Keep.")
      expect(text).not_to include("wrote:", "On Tue", "old stuff", "Original Message")
    end
  end

  describe "prompt modes" do
    let(:topic) { create(:topic) }
    let(:run) { create(:patchset_run, topic: topic, status: "running") }

    def readme(mode)
      Dir.mktmpdir do |dir|
        described_class.new(run: run, topic: topic, patchsets: [], candidates: [], pairs: [], commit_scores: [],
                            branches: {}, previous: nil, repo_path: "/repo", mode: mode).write(dir)
        return File.read(File.join(dir, "README.md"))
      end
    end

    before do
      stub_const("Lineage::JobBundle::PROMPT_PATH", Pathname.new(File.join(Dir.mktmpdir, "prompt.md")))
      File.write(Lineage::JobBundle::PROMPT_PATH, <<~MD)
        # Mode {{mode}}
        common
        <!-- trailer -->
        trailer only
        <!-- /trailer -->
        <!-- full -->
        full only
        <!-- /full -->
        tail
      MD
    end

    it "keeps only the trailer section in trailer mode" do
      text = readme("trailer")
      expect(text).to eq("# Mode trailer\ncommon\ntrailer only\ntail\n")
    end

    it "keeps only the full section in full mode" do
      text = readme("full")
      expect(text).to eq("# Mode full\ncommon\nfull only\ntail\n")
    end
  end

  it "renders the shipped prompt without markers in both modes" do
    topic = create(:topic)
    run = create(:patchset_run, topic: topic, status: "running")
    %w[trailer full].each do |mode|
      Dir.mktmpdir do |dir|
        described_class.new(run: run, topic: topic, patchsets: [], candidates: [], pairs: [], commit_scores: [],
                            branches: {}, previous: nil, repo_path: "/repo", mode: mode).write(dir)
        text = File.read(File.join(dir, "README.md"))
        expect(text).not_to include("<!--", "{{")
        expect(text.include?("Task 2b")).to be(mode == "full")
        expect(text.include?("take that as given")).to be(mode == "trailer")
      end
    end
  end

  it "ships a valid result schema" do
    schema = JSON.parse(File.read(Lineage::JobBundle::SCHEMA_PATH))
    expect(schema["required"]).to eq(%w[lineage verdicts extra_commits story])
  end
end
