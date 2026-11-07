require "rails_helper"

RSpec.describe Stats::Period::People do
  let(:now) { Time.zone.parse("2026-11-06 12:00") }
  let!(:fx) { build_stats_release_fixture }
  let(:people) { described_class.new(Stats::Period::Release.new(19)).to_h }

  before { travel_to(now) }

  def row(name) = people[:rows].find { |r| r[:name] == name }

  it "builds one row per credited person" do
    expect(people[:rows].map { |r| r[:name] }).to contain_exactly("Alice", "Bob", "Carol", "Dave")
    expect(row("Dave").slice(:committer, :authored, :reviewed, :committed, :messages, :threads, :company))
      .to eq(committer: true, authored: 2, reviewed: 0, committed: 1, messages: 0, threads: 0, company: nil)
    expect(row("Alice").slice(:committer, :authored, :reviewed, :committed, :messages, :threads, :company))
      .to eq(committer: true, authored: 1, reviewed: 0, committed: 3, messages: 1, threads: 1, company: "Acme")
    expect(row("Bob").slice(:committer, :authored, :reviewed, :committed, :messages, :threads, :company))
      .to eq(committer: false, authored: 1, reviewed: 0, committed: 0, messages: 5, threads: 2, company: "Gamma")
    expect(row("Carol").slice(:authored, :reviewed, :messages, :threads, :company)).to eq(authored: 0, reviewed: 1, messages: 1, threads: 1, company: "Acme")
    expect(row("Bob")[:email]).to eq("bob@example.com")
  end

  def scope_commit(at)
    create(:commit, committed_at: Time.zone.parse(at), branches: %w[REL_19_STABLE master])
  end

  def credit(commit, person, role)
    create(:commit_person, commit: commit, person: person, role: role, raw_name: person.display_name, raw_email: person.default_alias.email)
  end

  it "gives no credit for an unresolved author, not the committer" do
    commit = scope_commit("2026-03-01 12:00")
    credit(commit, fx.people["alice"], CommitPerson::COMMITTER)
    create(:commit_person, commit: commit, person: nil, role: "author", raw_name: "Nobody", raw_email: "nobody@example.com")
    expect(row("Alice").slice(:authored, :committed)).to eq(authored: 1, committed: 4)
    expect(people[:rows].map { |r| r[:name] }).to contain_exactly("Alice", "Bob", "Carol", "Dave")
    expect(people[:rows].sum { |r| r[:authored] }).to eq(4)
  end

  it "does not fall back to the committer when only an llm author exists" do
    commit = scope_commit("2026-03-03 12:00")
    credit(commit, fx.people["alice"], CommitPerson::COMMITTER)
    create(:commit_person, commit: commit, person: nil, role: "author", source: "llm", raw_name: "Nobody", raw_email: "nobody@example.com")
    expect(row("Alice").slice(:authored, :committed)).to eq(authored: 1, committed: 4)
    expect(people[:rows].sum { |r| r[:authored] }).to eq(4)
  end

  it "falls back to the committer when the llm author is the committer" do
    commit = scope_commit("2026-03-04 12:00")
    credit(commit, fx.people["alice"], CommitPerson::COMMITTER)
    create(:commit_person, commit: commit, person: fx.people["alice"], role: "author", source: "llm", raw_name: "Alice", raw_email: "alice@example.com")
    expect(row("Alice").slice(:authored, :committed)).to eq(authored: 2, committed: 4)
  end

  it "credits every author of a commit" do
    commit = scope_commit("2026-03-02 12:00")
    credit(commit, fx.people["alice"], CommitPerson::COMMITTER)
    credit(commit, fx.people["bob"], "author")
    credit(commit, fx.people["carol"], "author")
    expect(row("Bob")[:authored]).to eq(2)
    expect(row("Carol")[:authored]).to eq(1)
    expect(row("Alice").slice(:authored, :committed)).to eq(authored: 1, committed: 4)
    expect(row("Bob").slice(:messages, :threads)).to eq(messages: 5, threads: 2)
    expect(people[:totals]).to eq(authors: 4, reviewers: 1, people: 4)
  end

  it "totals the header line" do
    expect(people[:totals]).to eq(authors: 3, reviewers: 1, people: 4)
  end
end
