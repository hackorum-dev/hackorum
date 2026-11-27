require "rails_helper"

RSpec.describe "Search commit: selector", type: :service do
  let(:parser) { Search::QueryParser.new }
  let(:user) { create(:user) }

  let(:tom) { create(:person) }
  let!(:tom_alias) { create(:alias, name: "Tom Lane", email: "tgl@sss.pgh.pa.us", person: tom) }

  def link(topic, commit, source: "trailer")
    create(:commit_topic, topic: topic, commit: commit, source: source)
  end

  def credit(commit, role, source: "parsed")
    create(:commit_person, commit: commit, person: tom, role: role, source: source)
  end

  let!(:plain) { create(:topic) }
  let!(:reviewed) { create(:topic) }
  let!(:implied) { create(:topic) }
  let!(:llm_rev) { create(:topic) }
  let!(:backported) { create(:topic) }
  let!(:unreleased) { create(:topic) }
  let!(:fresh) { create(:topic) }
  let!(:llm_only) { create(:topic) }

  let!(:commit_a) { create(:commit, released_in: "18.1", committed_at: 40.days.ago) }
  let!(:commit_b) { create(:commit, released_in: "18.1", committed_at: 40.days.ago) }
  let!(:commit_c) { create(:commit, released_in: "18.1", committed_at: 40.days.ago) }
  let!(:commit_d) { create(:commit, released_in: "18beta1", committed_at: 40.days.ago) }
  let!(:commit_e) do
    create(:commit, cherry_picked_from_sha: commit_d.sha, released_in: "17.3",
                    branches: [ "REL_17_STABLE" ], committed_at: 40.days.ago)
  end
  let!(:commit_f) { create(:commit, released_in: nil, committed_at: 40.days.ago) }
  let!(:commit_g) do
    create(:commit, cherry_picked_from_sha: commit_f.sha, released_in: "17.4",
                    branches: [ "REL_17_STABLE" ], committed_at: 40.days.ago)
  end
  let!(:commit_h) { create(:commit, released_in: nil, committed_at: 1.day.ago) }
  let!(:commit_i) { create(:commit, released_in: "170.1", committed_at: 40.days.ago) }
  let!(:big_release_topic) { create(:topic) }

  before do
    link(reviewed, commit_a)
    credit(commit_a, "reviewer")
    link(implied, commit_b)
    credit(commit_b, "reviewer", source: "committer")
    link(llm_rev, commit_c)
    credit(commit_c, "reviewer", source: "llm")
    link(backported, commit_e)
    credit(commit_d, "author")
    link(unreleased, commit_f)
    link(unreleased, commit_g)
    link(fresh, commit_h)
    link(llm_only, create(:commit), source: "llm")
    link(big_release_topic, commit_i)
    Topic.refresh_commit_aggregates!(Topic.pluck(:id))
  end

  def build_query(query_string)
    ast = parser.parse(query_string)
    validated = Search::QueryValidator.new(ast).validate
    Search::QueryBuilder.new(ast: validated.ast, user: user).build
  end

  def ids(query)
    build_query(query).relation.pluck(:id)
  end

  it "has:commit counts both sources and excludes plain" do
    result = ids("has:commit")
    expect(result).to include(reviewed.id, llm_only.id, fresh.id)
    expect(result).not_to include(plain.id)
  end

  it "-has:commit is exactly the topics without links" do
    expect(ids("-has:commit")).to eq([ plain.id ])
  end

  it "matches parsed and committer reviewers, not llm" do
    result = ids('commit:[reviewer:"Tom Lane"]')
    expect(result).to include(reviewed.id, implied.id)
    expect(result).not_to include(llm_rev.id)
  end

  it "ties credit and release to the same change" do
    expect(ids('commit:[author:"Tom Lane", released:17]')).to include(backported.id)
  end

  it "keeps credit and release on one change within a single term" do
    mixed = create(:topic)
    link(mixed, create(:commit, released_in: "18.1", committed_at: 40.days.ago).tap { |c| credit(c, "reviewer") })
    link(mixed, create(:commit, released_in: "17.2", committed_at: 40.days.ago))
    Topic.refresh_commit_aggregates!([ mixed.id ])

    expect(ids('commit:[reviewer:"Tom Lane", released:17]')).not_to include(mixed.id)
    expect(ids('commit:[reviewer:"Tom Lane"] commit:[released:17]')).to include(mixed.id)
  end

  it "released:none excludes changes with a shipped backport" do
    result = ids("commit:[released:none]")
    expect(result).to include(fresh.id)
    expect(result).not_to include(unreleased.id)
  end

  it "matches released prefixes on component boundaries" do
    expect(ids("commit:[released:1]")).not_to include(backported.id)
    expect(ids("commit:[released:17.3]")).to include(backported.id)
    expect(ids("commit:[released:17.30]")).not_to include(backported.id)
  end

  it "released:17 does not match 170.1" do
    expect(ids("commit:[released:17]")).not_to include(big_release_topic.id)
    expect(ids("commit:[released:170]")).to include(big_release_topic.id)
  end

  it "filters by committed_after" do
    expect(ids("commit:[committed_after:2d]")).to eq([ fresh.id ])
  end

  it "finds by sha of the backport or its original" do
    expect(ids("commit:#{commit_e.sha[0, 8]}")).to include(backported.id)
    expect(ids("commit:#{commit_d.sha[0, 8]}")).to include(backported.id)
  end

  it "negates" do
    result = ids('-commit:[reviewer:"Tom Lane"]')
    expect(result).to include(plain.id, llm_rev.id)
    expect(result).not_to include(reviewed.id)
  end

  it "unresolved person matches none, negation all" do
    result = build_query("commit:[reviewer:nobody-matches-this]")
    expect(result.relation).to be_empty
    expect(result.warnings).not_to be_empty
    expect(ids("-commit:[reviewer:nobody-matches-this]").size).to eq(Topic.count)
  end

  it "has:later_fix and has:fixes follow direction" do
    t1 = create(:topic)
    t2 = create(:topic)
    create(:topic_link, topic: t1, other_topic: t2, kind: "fixes", direction: "in")
    create(:topic_link, topic: t2, other_topic: t1, kind: "fixes", direction: "out")
    expect(ids("has:later_fix")).to eq([ t1.id ])
    expect(ids("has:fixes")).to eq([ t2.id ])
  end
end
