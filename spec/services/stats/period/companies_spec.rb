require "rails_helper"

RSpec.describe Stats::Period::Companies do
  let(:now) { Time.zone.parse("2026-11-06 12:00") }
  let!(:fx) { build_stats_release_fixture }
  let(:companies) { described_class.new(Stats::Period::Release.new(19)).to_h }

  before { travel_to(now) }

  def row(name) = companies[:rows].find { |r| r[:company] == name }

  it "rolls credits up by the affiliation at commit time" do
    expect(companies[:rows].map { |r| r[:company] }).to eq([ "Acme", "Beta Corp", Stats::Affiliations::UNKNOWN ])
    expect(row("Acme").slice(:authored, :reviewed, :committed, :lines)).to eq(authored: 1, reviewed: 1, committed: 2, lines: 10)
    expect(row("Acme")[:people].map { |p| [ p[:name], p[:committer] ] }).to eq([ [ "Alice", true ], [ "Carol", false ] ])
    expect(row("Beta Corp").slice(:authored, :reviewed, :committed, :lines)).to eq(authored: 1, reviewed: 0, committed: 0, lines: 110)
    expect(row(Stats::Affiliations::UNKNOWN).slice(:authored, :reviewed, :committed, :lines)).to eq(authored: 2, reviewed: 0, committed: 0, lines: 30)
  end

  it "fills the tiles" do
    expect(companies[:tiles]).to eq(companies: 2, known_credits: 3, credits: 5, top5_authored: 2, authored_total: 4, with_committer: 1)
  end

  it "builds the monthly series on the pulse buckets" do
    m = companies[:monthly]
    expect(m[:buckets].size).to eq(19)
    labels = m[:buckets]
    authored = m[:authored].to_h { |s| [ s[:label], labels.zip(s[:values]).reject { |_, v| v.zero? }.to_h ] }
    expect(authored).to eq("Acme" => { "Jan 2026" => 1 }, "Beta Corp" => { "Oct 2025" => 1 },
                           "other companies" => {}, Stats::Affiliations::UNKNOWN => { "Feb 2026" => 1, "Jul 2026" => 1 })
    reviewed = m[:reviewed].to_h { |s| [ s[:label], labels.zip(s[:values]).reject { |_, v| v.zero? }.to_h ] }
    expect(reviewed["Acme"]).to eq("Oct 2025" => 1)
  end

  it "counts a commit reviewed by two companies for both" do
    erin = create(:alias, name: "Erin", email: "erin@example.com").person
    PersonAffiliation.create!(person: erin, company: "Delta", source: "manual")
    create(:commit_person, commit: fx.commits[:c1], person: erin, role: "reviewer", raw_name: "Erin", raw_email: "erin@example.com")
    expect(row("Acme")[:reviewed]).to eq(1)
    expect(row("Delta")[:reviewed]).to eq(1)
    expect(companies[:tiles].slice(:known_credits, :credits)).to eq(known_credits: 4, credits: 6)
  end

  def scope_commit(at, committer, lines_added: 0)
    commit = create(:commit, committed_at: Time.zone.parse(at), branches: %w[REL_19_STABLE master],
                             committer_name: committer.display_name, committer_email: committer.default_alias.email,
                             lines_added: lines_added, lines_removed: 0)
    create(:commit_person, commit: commit, person: committer, role: CommitPerson::COMMITTER,
                           raw_name: committer.display_name, raw_email: committer.default_alias.email)
    commit
  end

  it "gives no authored credit for an unresolved author and no fallback to the committer" do
    commit = scope_commit("2026-03-10 12:00", fx.people["alice"])
    create(:commit_person, commit: commit, person: nil, role: "author", raw_name: "Zed", raw_email: "zed@example.org")
    CommitterReviewer.sync!([ commit.id ])
    expect(row("Acme").slice(:authored, :committed)).to eq(authored: 1, committed: 3)
    expect(companies[:tiles][:authored_total]).to eq(4)
  end

  it "splits lines between resolved authors" do
    commit = scope_commit("2026-03-01 12:00", fx.people["dave"], lines_added: 20)
    %w[bob carol].each do |name|
      person = fx.people[name]
      create(:commit_person, commit: commit, person: person, role: "author", raw_name: person.display_name, raw_email: person.default_alias.email)
    end
    expect(row("Gamma").slice(:authored, :lines)).to eq(authored: 1, lines: 10)
    expect(row("Acme").slice(:authored, :lines)).to eq(authored: 2, lines: 20)
    expect(companies[:rows].sum { |r| r[:lines] }).to eq(110 + 10 + 20 + 10 + 20)
  end

  it "counts two authors from one company once per commit, lines split" do
    commit = scope_commit("2026-03-02 12:00", fx.people["dave"], lines_added: 20)
    %w[alice carol].each do |name|
      person = fx.people[name]
      create(:commit_person, commit: commit, person: person, role: "author", raw_name: person.display_name, raw_email: person.default_alias.email)
    end
    expect(row("Acme").slice(:authored, :lines)).to eq(authored: 2, lines: 30)
    expect(companies[:tiles][:authored_total]).to eq(5)
  end

  it "folds companies past the top ten into other companies" do
    ("A".."K").each_with_index do |letter, i|
      person = create(:alias, name: "Dev #{letter}", email: "dev#{letter.downcase}@example.com").person
      PersonAffiliation.create!(person: person, company: "Co #{letter}", source: "manual")
      commit = scope_commit("2026-04-#{10 + i} 12:00", fx.people["dave"])
      create(:commit_person, commit: commit, person: person, role: "author", raw_name: person.display_name, raw_email: "dev#{letter.downcase}@example.com")
    end
    m = companies[:monthly]
    expect(m[:authored].map { |s| s[:label] }).to eq([ "Acme", "Beta Corp", *("A".."H").map { |l| "Co #{l}" }, "other companies", Stats::Affiliations::UNKNOWN ])
    expect(m[:authored].map { |s| s[:fold] }).to eq([ false ] * 10 + [ true, true ])
    other = m[:authored].find { |s| s[:label] == "other companies" }
    expect(m[:buckets].zip(other[:values]).reject { |_, v| v.zero? }.to_h).to eq("Apr 2026" => 3)
    expect(companies[:tiles][:top5_authored]).to eq(5)
    expect(m[:windows].map { |w| w[:phase] }).to eq(%w[early middle late])
    expect(m[:windows].first.keys).to eq(%i[from to phase])
    expect(m[:windows].last[:to]).to eq(now.utc.iso8601)
  end

  it "treats an llm-only author as someone else: committed credit, no authored credit" do
    commit = scope_commit("2026-03-12 12:00", fx.people["alice"])
    bob = fx.people["bob"]
    create(:commit_person, commit: commit, person: bob, role: "author", source: "llm", raw_name: bob.display_name, raw_email: bob.default_alias.email)
    CommitterReviewer.sync!([ commit.id ])
    expect(row("Acme").slice(:authored, :committed)).to eq(authored: 1, committed: 3)
    expect(row("Gamma")).to be_nil
    expect(companies[:tiles][:authored_total]).to eq(4)
  end

  it "treats an llm author equal to the committer as own work" do
    commit = scope_commit("2026-03-14 12:00", fx.people["alice"])
    alice = fx.people["alice"]
    create(:commit_person, commit: commit, person: alice, role: "author", source: "llm", raw_name: alice.display_name, raw_email: alice.default_alias.email)
    CommitterReviewer.sync!([ commit.id ])
    expect(row("Acme").slice(:authored, :committed)).to eq(authored: 2, committed: 2)
  end

  it "gives committed credit to a committer who also lists themselves as reviewer" do
    commit = scope_commit("2026-03-16 12:00", fx.people["alice"])
    alice = fx.people["alice"]
    bob = fx.people["bob"]
    create(:commit_person, commit: commit, person: bob, role: "author", raw_name: bob.display_name, raw_email: bob.default_alias.email)
    create(:commit_person, commit: commit, person: alice, role: "reviewer", raw_name: alice.display_name, raw_email: alice.default_alias.email)
    CommitterReviewer.sync!([ commit.id ])
    expect(CommitPerson.committer_sourced.where(commit_id: commit.id)).to be_empty
    expect(row("Acme").slice(:reviewed, :committed)).to eq(reviewed: 2, committed: 3)
  end

  it "counts two reviewers from one company once per commit" do
    commit = scope_commit("2026-03-18 12:00", fx.people["dave"])
    %w[alice carol].each do |name|
      person = fx.people[name]
      create(:commit_person, commit: commit, person: person, role: "reviewer", raw_name: person.display_name, raw_email: person.default_alias.email)
    end
    expect(row("Acme")[:reviewed]).to eq(2)
    expect(row("Acme")[:people].map { |p| p[:name] }).to eq(%w[Alice Carol])
    expect(companies[:tiles].slice(:known_credits, :credits)).to eq(known_credits: 4, credits: 7)
    reviewed = companies[:monthly][:reviewed].find { |s| s[:label] == "Acme" }
    expect(companies[:monthly][:buckets].zip(reviewed[:values]).reject { |_, v| v.zero? }.to_h).to eq("Oct 2025" => 1, "Mar 2026" => 1)
  end
end
