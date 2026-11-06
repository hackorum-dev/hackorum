require "rails_helper"

RSpec.describe Stats::Release::Scopes do
  let(:now) { Time.zone.parse("2026-11-06 12:00") }
  let!(:fx) { build_stats_release_fixture }
  let(:scopes) { Stats::Release.new(19).scopes }

  before { travel_to(now) }

  it "collapses backports and applies the branch rule" do
    shas = scopes.commits.pluck(:sha)
    expect(shas).to contain_exactly(fx.commits[:c1].sha, fx.commits[:c2].sha, fx.commits[:c3].sha, fx.commits[:c4b].sha)
    expect(scopes.commits.count).to eq(4)
    expect(shas).not_to include(fx.commits[:c4d].sha)
  end

  it "leaves out a group that shipped on the previous branch before its GA" do
    fix = create(:commit, sha: "e1" * 20, subject: "Stabilization fix", committed_at: Time.zone.parse("2025-08-01 12:00"), branches: %w[master REL_19_STABLE])
    create(:commit, sha: "e2" * 20, subject: "Stabilization fix", committed_at: Time.zone.parse("2025-08-01 13:00"), branches: %w[REL_18_STABLE], cherry_picked_from_sha: fix.sha)
    late = create(:commit, sha: "e3" * 20, subject: "Minor release fix", committed_at: Time.zone.parse("2025-10-01 12:00"), branches: %w[master REL_19_STABLE])
    create(:commit, sha: "e4" * 20, subject: "Minor release fix", committed_at: Time.zone.parse("2025-10-01 13:00"), branches: %w[REL_18_STABLE], cherry_picked_from_sha: late.sha)
    shas = described_class.new(Stats::Release.new(19)).commits.pluck(:sha)
    expect(shas).not_to include(fix.sha)
    expect(shas).to include(late.sha)
  end

  it "counts groups backported to earlier branches" do
    expect(scopes.backported).to eq(2)
  end

  it "scopes the release in development to master, without what already shipped in 19" do
    only = create(:commit, sha: "e5" * 20, subject: "Master only", committed_at: Time.zone.parse("2026-08-01 12:00"), branches: %w[master])
    dev = Stats::Release.new(20).scopes
    expect(dev.commits.pluck(:sha)).to eq([ only.sha ])
    expect(dev.backported).to eq(0)
  end

  it "cuts a closed release at its GA tag" do
    create(:release_tag, name: "REL_19_0", released_at: Time.zone.parse("2026-06-15 20:00"))
    expect(Stats::Release.new(19).scopes.commits.pluck(:sha)).to contain_exactly(fx.commits[:c1].sha, fx.commits[:c2].sha, fx.commits[:c3].sha)
  end

  it "scopes threads through commit links" do
    expect(scopes.threads.pluck(:id)).to contain_exactly(fx.topics[:t1].id, fx.topics[:t2].id, fx.topics[:t4].id)
    expect(scopes.thread_messages.count).to eq(7)
  end

  it "applies the phase rule to messages" do
    early = scopes.messages_between(Time.zone.parse("2025-05-05"), Time.zone.parse("2025-09-22 20:00"))
    expect(early.pluck(:id)).to contain_exactly(fx.messages[:t1_v1].id, fx.messages[:t1_rev].id)

    middle = scopes.messages_between(Time.zone.parse("2025-09-22 20:00"), Time.zone.parse("2026-06-01 20:00"))
    expect(middle.count).to eq(6)

    late = scopes.messages_between(Time.zone.parse("2026-06-01 20:00"), now)
    expect(late.count).to eq(0)
  end

  it "leaves commit notification threads out of the middle phase" do
    list = create(:mailing_list, identifier: Stats::Release::Scopes::NOTICE_LIST, display_name: "comitters")
    notice = create(:topic, title: "pgsql: Fix thing", creator_alias: fx.people["alice"].default_alias, created_at: Time.zone.parse("2026-02-10 10:00"))
    create(:topic_mailing_list, topic: notice, mailing_list: list)
    create(:message, topic: notice, sender_alias: fx.people["alice"].default_alias, created_at: Time.zone.parse("2026-02-10 10:00"))
    middle = scopes.messages_between(Time.zone.parse("2025-09-22 20:00"), Time.zone.parse("2026-06-01 20:00"))
    expect(middle.count).to eq(6)
  end

  it "knows who has committed, and since when" do
    expect(scopes.committer_ids).to contain_exactly(fx.people["alice"].id, fx.people["dave"].id)
    expect(scopes.committer_since).to eq(fx.people["dave"].id => Time.zone.parse("2026-02-01 12:00"))
    expect(scopes.committer_at?(fx.people["dave"].id, Time.zone.parse("2026-01-31"))).to be(false)
    expect(scopes.committer_at?(fx.people["dave"].id, Time.zone.parse("2026-02-02"))).to be(true)
    expect(scopes.committer_at?(fx.people["bob"].id, Time.zone.parse("2026-02-02"))).to be(false)
    expect(scopes.committer_at?(nil, Time.zone.parse("2026-02-02"))).to be(false)
  end

  it "measures LLM coverage over the commits with a thread" do
    expect(scopes.llm_coverage).to eq(1.0)
    expect(scopes).to be_llm
    CommitVerdict.where(commit: fx.commits[:c4]).delete_all
    fresh = described_class.new(Stats::Release.new(19))
    expect(fresh.llm_coverage).to be_within(0.01).of(0.67)
    expect(fresh).not_to be_llm
  end
end
