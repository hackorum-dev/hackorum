require "rails_helper"

RSpec.describe "Thread page patchset lineage", type: :request do
  let(:topic) { create(:topic) }
  let!(:m1) { create(:message, topic: topic, is_patch_submission: true, created_at: 2.days.ago) }
  let!(:m2) { create(:message, topic: topic, is_patch_submission: true, created_at: 1.day.ago) }
  let(:commit) { create(:commit, subject: "Land the thing", sha: "c" * 40) }
  let(:extra_commit) { create(:commit, subject: "Revert the thing", sha: "d" * 40) }
  let(:other_commit) { create(:commit, subject: "Unrelated overlap", sha: "e" * 40) }
  let(:pending_commit) { create(:commit, subject: "Still undecided", sha: "f" * 40) }
  let!(:run) { create(:patchset_run, topic: topic, story: "v1 then v2 landed as c\n\nthen a fixup followed\n") }

  before do
    create(:patchset_lineage, patchset_run: run, topic: topic, message: m1, step_kind: "new_series", confidence: 1.0)
    create(:patchset_lineage, patchset_run: run, topic: topic, message: m2, parent_message: m1, step_kind: "rebase", confidence: 0.85, reason: "same hunks")
    create(:commit_verdict, patchset_run: run, topic: topic, commit: commit, verdict: "modified", source_message: m2, confidence: 0.9,
                            change_level: "moderate", evidence: "hunks from [msg:#{m2.id}] with a renamed helper",
                            reviewers_final: 1, reviewers_earlier: 1, reviewers_none: 0,
                            reviews: [ { "reviewer" => "Alice", "reviewed_message_ids" => [ m2.id ], "coverage" => "final", "note" => "looked at [msg:#{m2.id}]" },
                                       { "reviewer" => "Bob", "reviewed_message_ids" => [ m1.id ], "coverage" => "earlier", "note" => nil } ])
    create(:commit_verdict, patchset_run: run, topic: topic, commit: other_commit, verdict: "not_this_thread", origin: "overlap", confidence: 0.7)
    create(:commit_verdict, patchset_run: run, topic: topic, commit: pending_commit, verdict: "undecided", origin: "trailer", confidence: 0.5)
    create(:commit_topic, topic: topic, commit: commit, source: "llm", confidence: 0.9)
    create(:commit_verdict, patchset_run: run, topic: topic, commit: extra_commit, verdict: "from_discussion", confidence: 0.85, extra: true)
    commit.commit_people.create!(role: "author", raw_name: "Guessed Author", raw_email: "guessed@example.com",
                                 source: "llm", confidence: 0.9)
  end

  it "hides everything without the feature" do
    get topic_path(topic)
    expect(response.body).not_to include("v1 then v2 landed")
    expect(response.body).not_to include("Land the thing")
    expect(response.body).not_to include("found in git")
    expect(response.body).not_to include("Guessed Author")
    expect(response.body).not_to include("commit-credit-llm")
    get patchsets_sidebar_topic_path(topic)
    expect(response.body).not_to include("rebase")
  end

  it "shows lineage, verdicts and the LLM badge with the feature" do
    user = create(:user)
    create(:user_feature, user: user, feature: "patchset_lineage")
    sign_in_as(user)

    get topic_path(topic)
    expect(response.body).to include("<li>v1 then v2 landed as c</li><li>then a fixup followed</li>")
    expect(response.body).to include("Land the thing")
    expect(response.body).to include("commit-sidebar-llm")
    expect(response.body).to include("modified")
    expect(response.body).to include("Revert the thing")
    expect(response.body).to include("found in git")
    expect(response.body).to include("Still undecided")
    expect(response.body).not_to include("Unrelated overlap")
    expect(response.body).to include('class="lineage-change"')
    expect(response.body).to include(">moderate</span>")
    expect(response.body).to include("reviews: 1 of 2 reviewed the final version")
    expect(response.body).to include("Alice")
    expect(response.body).to include(%(hunks from <a href="#message-#{m2.id}">#2</a> with a renamed helper))
    expect(response.body).to include(%(looked at <a href="#message-#{m2.id}">#2</a>))
    expect(response.body).to include("Guessed Author")
    expect(response.body).to include('<span class="commit-credit-llm" title="Attributed by the patchset lineage model">LLM</span>')

    get patchsets_sidebar_topic_path(topic)
    expect(response.body).to include("from #1")
    expect(response.body).to include("rebase")
    expect(response.body).to include("85%")
  end
end
