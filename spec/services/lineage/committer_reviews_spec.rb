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

    it "counts llm and trailer rows alike" do
      rows = [ { "coverage" => "final", "source" => "trailer" }, { "coverage" => "earlier", "source" => "llm" } ]
      expect(described_class.counts(rows)).to eq(reviewers_final: 1, reviewers_earlier: 1, reviewers_none: 0)
    end
  end

  describe ".mirror" do
    let(:topic) { create(:topic) }
    let(:run) { create(:patchset_run, topic: topic) }
    let(:m) { create(:message, topic: topic, is_patch_submission: true) }
    let(:commit) { create(:commit) }

    before { create(:commit_person, commit: commit, role: "reviewer", source: CommitterReviewer::SOURCE, raw_name: "Neil Conway") }

    def verdict_for(commit, verdict: "modified", reviews: [])
      create(:commit_verdict, patchset_run: run, topic: topic, commit: commit, verdict: verdict, change_level: "light",
                              source_message: m, confidence: 0.9, reviews: reviews)
    end

    it "writes the committer as a final reviewer and recounts" do
      verdict = verdict_for(commit)

      expect(described_class.mirror([ verdict ])).to eq([ verdict ])
      verdict.reload
      expect(verdict.reviews).to eq([ { "reviewer" => "Neil Conway", "reviewed_message_ids" => [ m.id ], "coverage" => "final",
                                        "note" => described_class::NOTE, "source" => CommitterReviewer::SOURCE } ])
      expect(verdict.reviewers_final).to eq(1)
    end

    it "only reports with write: false" do
      verdict = verdict_for(commit)

      expect(described_class.mirror(CommitVerdict.where(id: verdict.id), write: false)).to eq([ verdict ])
      expect(verdict.reload.reviews).to eq([])
    end

    it "skips verdicts that are not committed" do
      verdict = verdict_for(commit, verdict: "not_this_thread")

      expect(described_class.mirror([ verdict ])).to eq([])
      expect(verdict.reload.reviews).to eq([])
    end

    it "skips when the reviewer is already listed" do
      existing = [ { "reviewer" => "neil conway", "reviewed_message_ids" => [], "coverage" => "earlier", "note" => "saw v1" } ]
      verdict = verdict_for(commit, reviews: existing)

      expect(described_class.mirror([ verdict ])).to eq([])
      expect(verdict.reload.reviews).to eq(existing)
    end

    it "skips commits without a committer reviewer row" do
      verdict = verdict_for(create(:commit))

      expect(described_class.mirror([ verdict ])).to eq([])
      expect(verdict.reload.reviews).to eq([])
    end
  end
end
