require "rails_helper"

RSpec.describe Lineage::CommitDiff do
  it "loads message and diff for a sha" do
    Dir.mktmpdir do |dir|
      fixture = GitFixtureRepo.new(dir)
      sha = fixture.commit(subject: "Add thing", body: "Discussion: x", files: { "src/backend/x.c" => "int x;\n" })
      entry = described_class.new(PatchBranches::GitRepo.new(dir)).fetch(sha)

      expect(entry.available).to be(true)
      expect(entry.message_text).to start_with("Add thing")
      expect(entry.diff_text).to include("+int x;")
      expect(entry.parsed.files.map(&:path)).to eq([ "src/backend/x.c" ])
    end
  end

  it "marks unknown shas unavailable" do
    Dir.mktmpdir do |dir|
      GitFixtureRepo.new(dir).commit(subject: "x")
      entry = described_class.new(PatchBranches::GitRepo.new(dir)).fetch("0" * 40)
      expect(entry.available).to be(false)
      expect(entry.parsed).to be_nil
      expect(entry.sha).to eq("0" * 40)
    end
  end
end
