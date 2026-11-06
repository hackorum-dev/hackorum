require "rails_helper"

RSpec.describe CommitterReviewer do
  let(:commit) { create(:commit) }
  let(:committer_person) { create(:person) }

  def committer!(c = commit, person: committer_person, name: "Neil Conway", email: "neil@example.com")
    create(:commit_person, commit: c, role: "committer", person: person, raw_name: name, raw_email: email)
  end

  def author!(c = commit, role: "author", source: "parsed", person: create(:person), name: "Dan Dev", email: "dan@example.com")
    create(:commit_person, commit: c, role: role, source: source, person: person, raw_name: name, raw_email: email,
                           confidence: source == "llm" ? 0.9 : nil)
  end

  def implied(c = commit) = CommitPerson.committer_sourced.where(commit_id: c.id)

  it "credits the committer as reviewer of someone else's patch, copying the committer fields" do
    committer!
    author!
    expect(described_class.sync!([ commit.id ])).to eq(1)
    expect(implied.sole).to have_attributes(role: "reviewer", person_id: committer_person.id, raw_name: "Neil Conway",
                                            raw_email: "neil@example.com", source: "committer")
  end

  it "writes nothing without an author or without a committer row" do
    committer!
    expect(described_class.sync!([ commit.id ])).to eq(0)
    other = create(:commit)
    author!(other)
    expect(described_class.sync!([ other.id ])).to eq(0)
    expect(CommitPerson.committer_sourced.count).to eq(0)
  end

  it "skips a committer who is an author by person, by email or by name" do
    committer!
    author!(person: committer_person, name: "N. Conway", email: "other@example.com")
    expect(described_class.sync!([ commit.id ])).to eq(0)

    CommitPerson.where(commit_id: commit.id).delete_all
    committer!(person: nil)
    author!(person: nil, name: "Someone", email: "NEIL@example.com")
    expect(described_class.sync!([ commit.id ])).to eq(0)

    CommitPerson.where(commit_id: commit.id).delete_all
    committer!(person: nil, email: nil)
    author!(person: nil, name: " neil conway ", email: nil)
    expect(described_class.sync!([ commit.id ])).to eq(0)
  end

  it "counts co_author and llm author rows as authors" do
    committer!
    author!(role: "co_author")
    expect(described_class.sync!([ commit.id ])).to eq(1)

    other = create(:commit)
    committer!(other)
    author!(other, source: "llm")
    expect(described_class.sync!([ other.id ])).to eq(1)
  end

  it "skips a committer already credited as reviewer by a trailer" do
    committer!
    author!
    create(:commit_person, commit: commit, role: "reviewer", person: committer_person, raw_name: "Neil Conway", raw_email: "neil@example.com")
    expect(described_class.sync!([ commit.id ])).to eq(0)
  end

  it "lists someone else's patch even when the committer is a trailer reviewer" do
    committer!
    author!
    create(:commit_person, commit: commit, role: "reviewer", person: committer_person, raw_name: "Neil Conway", raw_email: "neil@example.com")
    cr = described_class.new([ commit.id ])
    expect(cr.others_commit_ids).to eq([ commit.id ])
    expect(cr.entries).to be_empty
  end

  it "does not list own patches or commits without an author" do
    own = create(:commit)
    committer!(own)
    author!(own, person: committer_person)
    bare = create(:commit)
    committer!(bare)
    expect(described_class.new([ own.id, bare.id ]).others_commit_ids).to be_empty
  end

  it "is idempotent and follows authorship changes" do
    committer!
    author = author!
    described_class.sync!([ commit.id ])
    described_class.sync!([ commit.id ])
    expect(implied.count).to eq(1)

    author.update!(person: committer_person, raw_email: "neil@example.com")
    expect(described_class.sync!([ commit.id ])).to eq(0)
    expect(implied).to be_empty
  end

  it "handles an empty list" do
    expect(described_class.sync!([])).to eq(0)
  end

  it "treats different person ids with the same email as the same person" do
    committer!
    author!(email: "NEIL@example.com")
    expect(described_class.sync!([ commit.id ])).to eq(0)
  end

  it "does not match two resolved people by name" do
    committer!
    author!(name: "Neil Conway", email: "other@example.com")
    expect(described_class.sync!([ commit.id ])).to eq(1)
  end

  it "ignores an llm reviewer row naming the committer" do
    committer!
    author!
    create(:commit_person, commit: commit, role: "reviewer", source: "llm", confidence: 0.9, person: committer_person,
                           raw_name: "Neil Conway", raw_email: "neil@example.com")
    expect(described_class.sync!([ commit.id ])).to eq(1)
  end

  it "leaves commits outside the list alone" do
    second = create(:commit)
    committer!
    author = author!
    committer!(second)
    author!(second)
    described_class.sync!([ commit.id, second.id ])

    author.update!(person: committer_person, raw_email: "neil@example.com", raw_name: "Neil Conway")
    described_class.sync!([ commit.id ])
    expect(implied).to be_empty
    expect(implied(second).count).to eq(1)
  end
end
