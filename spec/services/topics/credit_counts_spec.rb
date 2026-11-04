require "rails_helper"

RSpec.describe Topics::CreditCounts do
  def counts(commits, sources: %w[parsed committer llm])
    described_class.new(Commit.group_backports(commits), sources: sources).by_role
  end

  it "counts a change and its backport once" do
    main = create(:commit, sha: "a1" * 20)
    back = create(:commit, sha: "b2" * 20, cherry_picked_from_sha: main.sha)
    [ main, back ].each { |c| c.commit_people.create!(role: "reviewer", raw_name: "Pavel Borisov") }

    entry = counts([ main, back ])["reviewer"].first
    expect(entry.total).to eq(1)
    expect(entry.llm).to eq(0)
  end

  it "splits llm and trailer credits for the same person" do
    c1, c2, c3 = create_list(:commit, 3)
    c1.commit_people.create!(role: "reviewer", raw_name: "Pavel Borisov")
    c2.commit_people.create!(role: "reviewer", raw_name: "Pavel Borisov", source: "llm", confidence: 0.8)
    c3.commit_people.create!(role: "reviewer", raw_name: "Pavel Borisov")
    c3.commit_people.create!(role: "reviewer", raw_name: "Pavel Borisov", source: "llm", confidence: 0.8)

    entry = counts([ c1, c2, c3 ])["reviewer"].first
    expect([ entry.total, entry.llm, entry.llm_only? ]).to eq([ 3, 1, false ])
  end

  it "marks model-only people" do
    c = create(:commit)
    c.commit_people.create!(role: "author", raw_name: "Guessed Author", source: "llm", confidence: 0.9)

    expect(counts([ c ])["author"].first.llm_only?).to be(true)
  end

  it "drops llm rows when the source list excludes them" do
    c = create(:commit)
    c.commit_people.create!(role: "author", raw_name: "Guessed Author", source: "llm", confidence: 0.9)

    expect(counts([ c ], sources: %w[parsed committer])).to eq({})
  end

  it "flags committer-sourced reviewers and merges a linked duplicate" do
    person = create(:person)
    create(:alias, name: "Tom Lane", email: "tgl@sss.pgh.pa.us", person: person)
    c1, c2 = create_list(:commit, 2)
    c1.commit_people.create!(role: "reviewer", raw_name: "Tom Lane")
    c2.commit_people.create!(role: "reviewer", raw_name: "Tom Lane", person: person, source: "committer")

    entry = counts([ c1, c2 ])["reviewer"].first
    expect(entry.total).to eq(2)
    expect(entry.committer).to be(true)
    expect(entry.email).to eq("tgl@sss.pgh.pa.us")
  end

  it "orders roles and people" do
    c1, c2 = create_list(:commit, 2)
    c1.commit_people.create!(role: "reported_by", raw_name: "Lakhin")
    c1.commit_people.create!(role: "author", raw_name: "Zed")
    c1.commit_people.create!(role: "author", raw_name: "Koval")
    c2.commit_people.create!(role: "author", raw_name: "Koval")

    result = counts([ c1, c2 ])
    expect(result.keys).to eq(%w[author reported_by])
    expect(result["author"].map(&:name)).to eq(%w[Koval Zed])
  end

  it "merges one linked person across raw name spellings" do
    person = create(:person)
    create(:alias, name: "Michael Paquier", email: "michael@paquier.xyz", person: person)
    c1, c2 = create_list(:commit, 2)
    c1.commit_people.create!(role: "author", raw_name: "Michael Paquier", person: person)
    c2.commit_people.create!(role: "author", raw_name: "Mich\u00ebl Paquier", person: person, source: "llm", confidence: 0.9)

    entries = counts([ c1, c2 ])["author"]
    expect(entries.size).to eq(1)
    expect([ entries.first.name, entries.first.total, entries.first.llm ]).to eq([ "Michael Paquier", 2, 1 ])
  end

  it "folds an unlinked row into the linked person with the same name" do
    person = create(:person)
    create(:alias, name: "Tom Lane", email: "tgl@sss.pgh.pa.us", person: person)
    c1, c2 = create_list(:commit, 2)
    c1.commit_people.create!(role: "reviewer", raw_name: "tom lane")
    c2.commit_people.create!(role: "reviewer", raw_name: "Tom Lane", person: person)

    entries = counts([ c1, c2 ])["reviewer"]
    expect(entries.size).to eq(1)
    expect([ entries.first.total, entries.first.email ]).to eq([ 2, "tgl@sss.pgh.pa.us" ])
  end

  it "leaves an unlinked row alone when several linked people share its name" do
    p1, p2 = create_list(:person, 2)
    create(:alias, name: "Tom Lane", email: "tgl@sss.pgh.pa.us", person: p1)
    create(:alias, name: "Tom Lane", email: "other@example.com", person: p2)
    c1, c2, c3 = create_list(:commit, 3)
    c1.commit_people.create!(role: "reviewer", raw_name: "Tom Lane")
    c2.commit_people.create!(role: "reviewer", raw_name: "Tom Lane", person: p1)
    c3.commit_people.create!(role: "reviewer", raw_name: "Tom Lane", person: p2)

    entries = counts([ c1, c2, c3 ])["reviewer"]
    expect(entries.map(&:total)).to eq([ 1, 1, 1 ])
  end
end
