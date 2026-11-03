require "rails_helper"

RSpec.describe "Admin::PatchsetRuns", type: :request do
  it "redirects non-admins" do
    sign_in_as(create(:user, admin: false))
    get admin_patchset_runs_path
    expect(response).to redirect_to(root_path)
  end

  it "lists and shows runs for admins" do
    sign_in_as(create(:user, admin: true))
    topic = create(:topic, title: "Lineage topic")
    run = create(:patchset_run, topic: topic, input_tokens: 1234, duration_s: 42.0)
    sha = "b" * 40
    create(:commit_verdict, patchset_run: run, topic: topic, verdict: "as_is", origin: "overlap", change_level: "light",
                            reviewers_final: 2, reviewers_earlier: 0, reviewers_none: 1, evidence: "matches [commit:#{sha}] exactly")
    create(:commit_topic, topic: topic, commit: create(:commit), source: "llm", confidence: 0.9)
    create(:commit_verdict, patchset_run: run, topic: topic, verdict: "from_discussion", extra: true)
    forwarded = create(:message, topic: topic, sender_alias: create(:alias, name: "Carol Contributor"))
    create(:commit_verdict, patchset_run: run, topic: topic, verdict: "modified", change_level: "light",
                            author_name: "Carol C.", author_message_id: forwarded.id)
    create(:commit_verdict, patchset_run: run, topic: topic, verdict: "modified", change_level: "light", author_name: "Dan Drifter")

    small = create(:topic, title: "Small topic")
    create(:patchset_run, topic: small, input_tokens: 10)

    get admin_patchset_runs_path(sort: "tokens")
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Lineage topic")
    expect(response.body).to include("1234")
    expect(response.body.index("Lineage topic")).to be < response.body.index("Small topic")
    expect(response.body).to include("as_is: 1")
    expect(response.body).to include("<th>Links</th>")
    expect(response.body).to include("<td>1</td>")

    get admin_patchset_run_path(run)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Patchsets 1-3 became commit A.")
    expect(response.body).to include("as_is")
    expect(response.body).to include("<th>Extra</th>")
    expect(response.body).to include("<td>yes</td>")
    expect(response.body).to include("<th>Origin</th>")
    expect(response.body).to include("<th>Change</th>")
    expect(response.body).to include("<th>Reviews (final/earlier/none)</th>")
    expect(response.body).to include("<td>overlap</td>")
    expect(response.body).to include("<td>light</td>")
    expect(response.body).to include("<td>2/0/1</td>")
    expect(response.body).to include("<th>Author</th>")
    expect(response.body).to include("<td>via sender</td>")
    expect(response.body).to include("<td>Carol Contributor (#{forwarded.id})</td>")
    expect(response.body).to include("<td>Dan Drifter</td>")
    expect(response.body).to include(%(matches <a target="_blank" rel="noopener" href="https://github.com/postgres/postgres/commit/#{sha}">bbbbbbbbbb</a> exactly))
  end
end
