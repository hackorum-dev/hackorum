require "rails_helper"

RSpec.describe "Thread sidebar commits", type: :request do
  def link_topic(topic, commit)
    create(:commit_topic, commit: commit, topic: topic)
    topic.update_columns(commit_count: topic.commit_topics.count)
  end

  it "shows commits with branch badges and a commit link" do
    topic = create(:topic, :with_messages)
    commit = create(:commit, subject: "Fix the vacuum leader race", sha: "abc123def456",
                             branches: [ "REL_18_STABLE" ], released_in: "18.5",
                             committer_name: "Alvaro Herrera")
    link_topic(topic, commit)

    get topic_path(topic)

    expect(response.body).to include("Commits")
    expect(response.body).to include("Fix the vacuum leader race")
    expect(response.body).to include("https://github.com/postgres/postgres/commit/abc123def456")
    expect(response.body).to include("Alvaro Herrera")
  end

  it "shows credits and links resolved people" do
    person = create(:person)
    create(:alias, name: "Tom Lane", email: "tgl@sss.pgh.pa.us", person: person)
    topic = create(:topic, :with_messages)
    commit = create(:commit)
    commit.commit_people.create!(role: "reviewer", raw_name: "Tom Lane",
                                 raw_email: "tgl@sss.pgh.pa.us", person: person)
    commit.commit_people.create!(role: "reported_by", raw_name: "buildfarm member koel")
    link_topic(topic, commit)

    get commits_details_topic_path(topic)

    expect(response.body).to include("Credits across")
    expect(response.body).to include("Tom Lane")
    expect(response.body).to include("/person/tgl@sss.pgh.pa.us")
    expect(response.body).to include("buildfarm member koel")
  end

  it "deduplicates credits across backports" do
    topic = create(:topic, :with_messages)
    canonical = create(:commit, sha: "aaa1", subject: "Shared change")
    backport = create(:commit, sha: "bbb2", subject: "Shared change", cherry_picked_from_sha: "aaa1")
    [ canonical, backport ].each do |commit|
      commit.commit_people.create!(role: "reviewer", raw_name: "Tom Lane", raw_email: "tgl@sss.pgh.pa.us")
      link_topic(topic, commit)
    end

    get commits_details_topic_path(topic)

    expect(response.body.scan("Tom Lane").size).to eq(1)
  end

  it "renders no commit sections for a topic without commits" do
    topic = create(:topic, :with_messages)

    get topic_path(topic)

    expect(Nokogiri::HTML(response.body).at_css("#topic-commits-modal")).to be_nil
  end
end
