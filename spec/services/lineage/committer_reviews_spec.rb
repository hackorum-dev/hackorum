require "rails_helper"

RSpec.describe Lineage::CommitterReviews do
  describe ".names" do
    it "matches reviewers to the committer by person, by trailer name and by the commit header" do
      person = create(:person)
      commit = create(:commit, committer_name: "Head Name")
      backport = create(:commit, cherry_picked_from_sha: commit.sha, committer_name: "Head Name")
      rows = [
        create(:commit_person, commit: commit, role: "committer", raw_name: "Alice Smith", person: person),
        create(:commit_person, commit: commit, role: "reviewer", raw_name: "A. Smith", person: person),
        create(:commit_person, commit: commit, role: "reviewer", raw_name: "Bob Jones", person: create(:person)),
        create(:commit_person, commit: backport, role: "reviewer", raw_name: "head name", person: nil),
        create(:commit_person, commit: backport, role: "committer", raw_name: "Carol King", person: nil),
        create(:commit_person, commit: backport, role: "reviewer", raw_name: "Carol King", person: create(:person))
      ]
      expect(described_class.names([ commit, backport ], rows)).to eq([ "A. Smith", "head name", "Carol King" ])
    end

    it "ignores llm rows" do
      commit = create(:commit)
      rows = [ create(:commit_person, commit: commit, role: "reviewer", raw_name: "Alice Smith", source: "llm") ]
      expect(described_class.names([ commit ], rows)).to eq([])
    end
  end

  describe ".apply" do
    let(:rows) do
      [ { "reviewer" => "Alice Smith", "reviewed_message_ids" => [], "coverage" => "none", "note" => "not assessed" },
        { "reviewer" => "Bob Jones", "reviewed_message_ids" => [ 1 ], "coverage" => "earlier", "note" => "saw v1" },
        { "reviewer" => "Dan Hill", "reviewed_message_ids" => [ 2 ], "coverage" => "final", "note" => "saw v2" } ]
    end

    it "forces final for committers, keeps everyone else" do
      out = described_class.apply(rows, [ "alice smith", "Bob Jones" ], 2)
      expect(out).to eq([
        { "reviewer" => "Alice Smith", "reviewed_message_ids" => [ 2 ], "coverage" => "final", "note" => "committed the patch; not assessed" },
        { "reviewer" => "Bob Jones", "reviewed_message_ids" => [ 1, 2 ], "coverage" => "final", "note" => "committed the patch; saw v1" },
        { "reviewer" => "Dan Hill", "reviewed_message_ids" => [ 2 ], "coverage" => "final", "note" => "saw v2" } ])
    end

    it "leaves a committer already at final alone and copes without a source patchset" do
      out = described_class.apply(rows, [ "Dan Hill", "Alice Smith" ], nil)
      expect(out[2]).to eq(rows[2])
      expect(out[0]).to include("coverage" => "final", "reviewed_message_ids" => [])
    end
  end

  describe ".counts" do
    it "tallies coverage" do
      rows = [ { "coverage" => "final" }, { "coverage" => "final" }, { "coverage" => "none" } ]
      expect(described_class.counts(rows)).to eq(reviewers_final: 2, reviewers_earlier: 0, reviewers_none: 1)
    end
  end
end
