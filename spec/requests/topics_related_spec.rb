require "rails_helper"

RSpec.describe "Related threads", type: :request do
  it "shows the block and the modal" do
    commit = create(:commit)
    a = create(:topic, title: "Bug A").tap { |t| create(:message, topic: t) }
    b = create(:topic, title: "Patch B").tap { |t| create(:message, topic: t, is_patch_submission: true) }
    [ a, b ].each { |t| create(:commit_topic, topic: t, commit: commit) }
    TopicLinks.sync_commits!([ commit.id ])
    get topic_path(a)
    expect(response.body).to include("Related threads", "Patch B", "same commit")
    get related_details_topic_path(a)
    expect(response.body).to include("Patch B")
    get commits_details_topic_path(a)
    expect(response.body).to include("Also in:", "Patch B")
  end

  it "has no block without links" do
    t = create(:topic).tap { |x| create(:message, topic: x) }
    get topic_path(t)
    expect(response.body).not_to include("Related threads")
  end
end
