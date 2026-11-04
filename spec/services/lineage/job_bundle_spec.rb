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
      described_class.new(run: run, topic: topic, patchsets: [ patchset ],
                          candidates: [ { commit: commit, origin: "trailer", overlap: nil,
                                          backports: [ backport ], reviewers: [ "Some Reviewer" ] } ],
                          pairs: [], branches: { m1.id => { status: "applied" } },
                          previous: nil, mode: "trailer").write(dir)

      index = JSON.parse(File.read(File.join(dir, "index.json")))
      expect(index["topic"]["id"]).to eq(topic.id)
      expect(index["patchsets"].first).to include("message_id" => m1.id, "ordinal" => 2, "dir" => "patchsets/002")
      expect(index["patchsets"].first["branch"]).to eq({ "status" => "applied" })
      expect(index["candidates"].first).to include("sha" => "a" * 40, "origin" => "trailer",
                                                   "backports" => [ "b" * 40 ], "reviewers" => [ "Some Reviewer" ])
      expect(index["mode"]).to eq("trailer")
      expect(index["through_message_id"]).to eq(m1.id)
      expect(index).not_to have_key("repo_path")

      msg2 = File.read(File.join(dir, "messages", "002.txt"))
      expect(msg2).to include("Patchset: patchsets/002")
      expect(msg2).to include("Here is v1.")
      expect(msg2).not_to include("> first idea")
      expect(msg2).not_to include("wrote:")
      expect(JSON.parse(File.read(File.join(dir, "pairs.json")))).to eq([])
      expect(index).not_to include("pairs", "commit_scores")
      readme = File.read(File.join(dir, "README.md"))
      expect(readme).to include("Row pattern recognition")
      expect(readme).to include("{{repo_path}}")
      expect(described_class.prompt_version).to match(/\A[0-9a-f]{12}\z/)
    end
  end

  it "strips gmail attributions and original message tails" do
    topic = create(:topic)
    create(:message, topic: topic, created_at: 2.days.ago,
           body: "Reply.\nOn Tue, Jan 1, 2025 at 10:00 AM Some Body <s@example.com>\nwrote:\n> q\nKeep.\n-----Original Message-----\nold stuff\n")
    run = create(:patchset_run, topic: topic, status: "running")
    Dir.mktmpdir do |dir|
      described_class.new(run: run, topic: topic, patchsets: [], candidates: [], pairs: [],
                          branches: {}, previous: nil, mode: "full").write(dir)
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
        described_class.new(run: run, topic: topic, patchsets: [], candidates: [], pairs: [],
                            branches: {}, previous: nil, mode: mode).write(dir)
        return File.read(File.join(dir, "README.md"))
      end
    end

    before do
      stub_const("Lineage::JobBundle::PROMPT_PATH", Pathname.new(File.join(Dir.mktmpdir, "prompt.md")))
      File.write(Lineage::JobBundle::PROMPT_PATH, <<~MD)
        # Mode {{mode}}
        common
        <!-- trailer full -->
        <!-- trailer -->
        trailer only
        <!-- /trailer -->
        <!-- full -->
        full only
        <!-- /full -->
        judged
        <!-- /trailer full -->
        <!-- lineage -->
        lineage only
        <!-- /lineage -->
        tail
      MD
    end

    it "keeps only the trailer section in trailer mode" do
      expect(readme("trailer")).to eq("# Mode trailer\ncommon\ntrailer only\njudged\ntail\n")
    end

    it "keeps only the full section in full mode" do
      expect(readme("full")).to eq("# Mode full\ncommon\nfull only\njudged\ntail\n")
    end

    it "keeps only the lineage section in lineage mode" do
      expect(readme("lineage")).to eq("# Mode lineage\ncommon\nlineage only\ntail\n")
    end
  end

  it "renders the shipped prompt without markers in all modes" do
    topic = create(:topic)
    run = create(:patchset_run, topic: topic, status: "running")
    %w[trailer full lineage].each do |mode|
      Dir.mktmpdir do |dir|
        described_class.new(run: run, topic: topic, patchsets: [], candidates: [], pairs: [],
                            branches: {}, previous: nil, mode: mode).write(dir)
        readme = File.read(File.join(dir, "README.md"))
        expect(readme).not_to include("<!--")
        expect(readme.scan(/\{\{\w+\}\}/).uniq).to eq([ "{{repo_path}}" ])
        expect(readme.include?("Task 2b")).to be(mode == "full")
        expect(readme.include?("## Task 3")).to be(mode != "lineage")
        expect(readme.include?("take that as given")).to be(mode == "trailer")
        if mode == "lineage"
          expect(readme).not_to include("## Task 2: commit verdicts")
          expect(readme).to include("`verdicts` and `extra_commits` must be `[]`")
        else
          expect(readme).to include("## Task 2: commit verdicts")
        end
      end
    end
  end

  it "ships a valid result schema" do
    schema = JSON.parse(File.read(Lineage::JobBundle::SCHEMA_PATH))
    expect(schema["required"]).to eq(%w[lineage verdicts extra_commits story])
  end
end
