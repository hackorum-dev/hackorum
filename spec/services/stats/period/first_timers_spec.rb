require "rails_helper"

RSpec.describe Stats::Period::FirstTimers do
  let(:now) { Time.zone.parse("2026-11-06 12:00") }
  let(:year) { Stats::Period::Year.new(2025) }

  before { travel_to(now) }

  def credit(person, at, role: "author", source: "parsed")
    commit = create(:commit, committed_at: at, branches: [ "master" ])
    create(:commit_person, commit: commit, person: person, role: role, source: source)
  end

  it "counts people whose first credit falls in the period" do
    newbie = create(:person)
    veteran = create(:person)
    reviewer = create(:person)
    credit(newbie, Time.zone.parse("2025-03-01"))
    credit(newbie, Time.zone.parse("2025-04-01"))
    credit(veteran, Time.zone.parse("2024-06-01"))
    credit(veteran, Time.zone.parse("2025-05-01"))
    credit(reviewer, Time.zone.parse("2025-06-01"), role: "reviewer")
    expect(described_class.new(year).count).to eq(2)
  end

  it "ignores unresolved and non-parsed credits" do
    credit(create(:person), Time.zone.parse("2025-03-01"), source: "llm")
    commit = create(:commit, committed_at: Time.zone.parse("2025-03-01"))
    create(:commit_person, commit: commit, person: nil, role: "author")
    expect(described_class.new(year).count).to eq(0)
  end

  it "needs a credit on a commit of the period" do
    credit(create(:person), Time.zone.parse("2026-02-01"))
    expect(described_class.new(year).count).to eq(0)
  end

  it "gives a backported change one home, by its master copy" do
    person = create(:person)
    master = create(:commit, sha: "a" * 40, committed_at: Time.zone.parse("2024-12-01"), branches: [ "master" ])
    pick = create(:commit, committed_at: Time.zone.parse("2025-01-10"), branches: [ "REL_17_STABLE" ], cherry_picked_from_sha: master.sha)
    create(:commit_person, commit: pick, person: person)
    create(:commit_person, commit: master, person: person)
    expect(described_class.new(year).count).to eq(0)
    expect(described_class.new(Stats::Period::Year.new(2024)).count).to eq(1)
  end
end
