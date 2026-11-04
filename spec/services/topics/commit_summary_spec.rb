require "rails_helper"

RSpec.describe Topics::CommitSummary do
  def summary(commits, sources: %w[parsed committer])
    described_class.new(commits, credit_sources: sources)
  end

  let(:t0) { Time.zone.parse("2024-04-06 10:00") }

  it "orders groups newest first and exposes first and latest" do
    old = create(:commit, sha: "a" * 40, subject: "Implement split", committed_at: t0)
    new = create(:commit, sha: "b" * 40, subject: "Docs fix", committed_at: t0 + 60.days)
    s = summary([ new, old ])

    expect(s.count).to eq(2)
    expect(s.latest[:sha]).to eq(new.sha)
    expect(s.first[:sha]).to eq(old.sha)
  end

  it "lists committers and canonical authors by frequency" do
    c1 = create(:commit, committer_name: "Alexander Korotkov", committed_at: t0)
    c2 = create(:commit, committer_name: "Alexander Korotkov", committed_at: t0 + 1.day)
    c3 = create(:commit, committer_name: "Robert Haas", committed_at: t0 + 2.days)
    back = create(:commit, cherry_picked_from_sha: c1.sha, committer_name: "Alexander Korotkov", committed_at: t0 + 3.days)
    c1.commit_people.create!(role: "author", raw_name: "Dmitry Koval")
    c2.commit_people.create!(role: "author", raw_name: "Dmitry Koval")
    c3.commit_people.create!(role: "author", raw_name: "Tender Wang")
    back.commit_people.create!(role: "author", raw_name: "Backport Only")
    c3.commit_people.create!(role: "author", raw_name: "Model Guess", source: "llm")

    s = summary([ c1, c2, c3, back ])

    expect(s.committers).to eq([ "Alexander Korotkov", "Robert Haas" ])
    expect(s.authors).to eq([ "Dmitry Koval", "Backport Only", "Tender Wang" ])
  end

  it "excludes llm-only authors but keeps people with a trailer credit too" do
    c1 = create(:commit, committed_at: t0)
    c2 = create(:commit, committed_at: t0 + 1.day)
    c1.commit_people.create!(role: "author", raw_name: "Mixed Person")
    c2.commit_people.create!(role: "author", raw_name: "Mixed Person", source: "llm", confidence: 0.9)
    c2.commit_people.create!(role: "author", raw_name: "Guess Only", source: "llm", confidence: 0.9)

    expect(summary([ c1, c2 ], sources: %w[parsed committer llm]).authors).to eq([ "Mixed Person" ])
  end

  describe "reverts" do
    let!(:feature) { create(:commit, sha: "1adf16b8fba45f77056d91573cd7138ed9da4ebf", subject: "Implement MERGE", committed_at: t0) }
    let!(:fix) { create(:commit, sha: "c99ef1811a064a94fb78917f35bb5853059a92b7", subject: "Checks", committed_at: t0 + 1.day) }

    it "counts thread commits named by sha prefix in the body" do
      revert = create(:commit, subject: "Revert support for MERGE", committed_at: t0 + 100.days,
                               body: "This commit reverts 1adf16b8fb, and c99ef1811a and deadbeef12.")
      s = summary([ feature, fix, revert ])
      group = s.groups.find { |g| g[:sha] == revert.sha }

      expect(described_class.revert?(group)).to be(true)
      expect(s.reverted_count(group)).to eq(2)
      expect(s.revert_groups.map { |g| g[:sha] }).to eq([ revert.sha ])
    end

    it "lists every member sha of a revert group" do
      revert = create(:commit, subject: "Revert support for MERGE", committed_at: t0 + 100.days)
      backport = create(:commit, subject: "Revert support for MERGE", committed_at: t0 + 101.days, cherry_picked_from_sha: revert.sha)
      s = summary([ feature, revert, backport ])

      expect(s.revert_shas).to eq(Set[ revert.sha, backport.sha ])
    end

    it "claims nothing when the body names no thread commit" do
      revert = create(:commit, subject: "Revert \"something\"", committed_at: t0 + 100.days,
                               body: "This reverts commit 0123456789abcdef0123456789abcdef01234567.")
      s = summary([ feature, revert ])
      group = s.groups.find { |g| g[:sha] == revert.sha }

      expect(described_class.revert?(group)).to be(true)
      expect(s.reverted_count(group)).to eq(0)
    end

    it "does not treat a subject merely mentioning revert as one" do
      other = create(:commit, subject: "Fix the revert path in pg_rewind", committed_at: t0 + 3.days)
      s = summary([ other ])

      expect(described_class.revert?(s.groups.first)).to be(false)
    end
  end

  it "splits clusters on gaps over 14 days" do
    a = create(:commit, committed_at: t0)
    b = create(:commit, committed_at: t0 + 10.days)
    c = create(:commit, committed_at: t0 + 40.days)
    s = summary([ a, b, c ])

    expect(s.clusters.map { |cl| cl.map { |g| g[:sha] } }).to eq([ [ c.sha ], [ b.sha, a.sha ] ])
  end
end
