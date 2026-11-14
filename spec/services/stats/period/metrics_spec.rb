require "rails_helper"

RSpec.describe Stats::Period::Metrics do
  let(:now) { Time.zone.parse("2026-11-06 12:00") }
  let!(:fx) { build_stats_release_fixture }
  let(:scopes) { Stats::Period::Release.new(19).scopes }

  before { travel_to(now) }

  it "computes the whole scope like Overview does" do
    m = described_class.new(scopes, scopes.commit_ids.pluck(:id))
    expect(m.count).to eq(4)
    expect(m.reverts).to eq(1)
    expect(m.lines).to eq([ 132, 18 ])
    expect(m.with_thread).to eq(3)
    expect(m.verdict_counts).to eq(as_is: 2, modified: 1, partial: 0, from_discussion: 0)
    expect(m.chain_lengths).to eq([ 3 ])
    expect(m.cf_commits).to eq(2)
    expect(m.trailer_coverage).to eq(final: 1, earlier: 0, none: 0)
    expect(m.by_others_ids).to contain_exactly(fx.commits[:c1].id, fx.commits[:c4b].id)
    expect(m.alone_ids).to eq([ fx.commits[:c4b].id ])
  end

  it "restricts to a subset" do
    m = described_class.new(scopes, [ fx.commits[:c1].id, fx.commits[:c4b].id ])
    expect(m.count).to eq(2)
    expect(m.reverts).to eq(0)
    expect(m.verdict_counts[:as_is]).to eq(2)
    expect(m.thread_ages_days.map(&:round)).to contain_exactly(40, 12)
    expect(m.credited_counts).to eq(fx.commits[:c1].id => 1)
    expect(m.judged_ids).to contain_exactly(fx.commits[:c1].id, fx.commits[:c4b].id)
  end

  it "restricts to own and others' commits" do
    m = described_class.new(scopes, [ fx.commits[:c1].id, fx.commits[:c2].id ])
    expect(m.judged_ids).to eq([ fx.commits[:c1].id ])
    expect(m.alone_ids).to eq([])
    expect(m.cf_commits).to eq(2)
    expect(m.with_thread).to eq(2)
    expect(m.chain_lengths).to eq([ 3 ])
  end

  it "does not count the committer's own reviewer credit as someone else's review" do
    alice = fx.people["alice"]
    bob = fx.people["bob"]
    commit = create(:commit, committed_at: Time.zone.parse("2026-03-20 12:00"), branches: %w[REL_19_STABLE master],
                             committer_name: "Alice", committer_email: "alice@example.com", lines_added: 4, lines_removed: 0)
    { CommitPerson::COMMITTER => alice, "author" => bob, "reviewer" => alice }.each do |role, person|
      create(:commit_person, commit: commit, person: person, role: role, raw_name: person.display_name, raw_email: person.default_alias.email)
    end
    topic = create(:topic, title: "t5", creator_alias: bob.default_alias, created_at: Time.zone.parse("2026-03-01"))
    run = create(:patchset_run, topic: topic)
    create(:commit_verdict, patchset_run: run, topic: topic, commit: commit, verdict: "as_is", source_message: nil, confidence: 1.0,
                            reviewers_final: 1, reviewers_earlier: 0, reviewers_none: 0,
                            reviews: [ { "reviewer" => "Alice", "source" => "trailer", "coverage" => "final", "reviewed_message_ids" => [], "note" => "" } ])

    m = described_class.new(scopes, [ commit.id ])
    expect(m.judged_ids).to eq([ commit.id ])
    expect(m.alone_ids).to eq([ commit.id ])
  end

  it "knows the backported group keys" do
    expect(scopes.backported_keys).to contain_exactly(fx.commits[:c3].sha, fx.commits[:c4].sha)
  end
end
