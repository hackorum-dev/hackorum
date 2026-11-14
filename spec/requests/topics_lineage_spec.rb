require "rails_helper"

RSpec.describe "Thread page patchset lineage", type: :request do
  let(:topic) { create(:topic) }
  let!(:m1) { create(:message, topic: topic, is_patch_submission: true, created_at: 2.days.ago) }
  let!(:m2) { create(:message, topic: topic, is_patch_submission: true, created_at: 1.day.ago) }
  let(:commit) { create(:commit, subject: "Land the thing", sha: "c" * 40) }
  let(:extra_commit) { create(:commit, subject: "Revert the thing", sha: "d" * 40) }
  let(:other_commit) { create(:commit, subject: "Unrelated overlap", sha: "e" * 40) }
  let(:pending_commit) { create(:commit, subject: "Still undecided", sha: "f" * 40) }
  let(:trailer_commit) { create(:commit, subject: "Trailer-linked thing", sha: "a" * 40) }
  let!(:run) { create(:patchset_run, topic: topic, story: "v1 then v2 landed as c\n\nthen a fixup followed\n") }

  before do
    create(:patchset_lineage, patchset_run: run, topic: topic, message: m1, step_kind: "new_series", confidence: 1.0)
    create(:patchset_lineage, patchset_run: run, topic: topic, message: m2, parent_message: m1, step_kind: "rebase", confidence: 0.85, reason: "same hunks")
    create(:commit_verdict, patchset_run: run, topic: topic, commit: commit, verdict: "modified", source_message: m2, confidence: 0.9,
                            change_level: "moderate", evidence: "hunks from [msg:#{m2.id}] with a renamed helper",
                            reviewers_final: 3, reviewers_earlier: 1, reviewers_none: 0,
                            reviews: [ { "reviewer" => "Alice", "reviewed_message_ids" => [ m2.id ], "coverage" => "final", "note" => "looked at [msg:#{m2.id}]" },
                                       { "reviewer" => "Bob", "reviewed_message_ids" => [ m1.id ], "coverage" => "earlier", "note" => nil, "source" => "trailer" },
                                       { "reviewer" => "Guessed Reviewer", "reviewed_message_ids" => [ m2.id ], "coverage" => "final", "note" => "tested it",
                                         "source" => "llm", "reviewer_message_id" => nil, "confidence" => 0.8 },
                                       { "reviewer" => "Neil Committer", "reviewed_message_ids" => [ m2.id ], "coverage" => "final",
                                         "note" => "committed the patch", "source" => "committer" } ])
    create(:commit_verdict, patchset_run: run, topic: topic, commit: other_commit, verdict: "not_this_thread", origin: "overlap", confidence: 0.7)
    create(:commit_verdict, patchset_run: run, topic: topic, commit: pending_commit, verdict: "undecided", origin: "trailer", confidence: 0.5)
    create(:commit_topic, topic: topic, commit: commit, source: "llm", confidence: 0.9)
    create(:commit_verdict, patchset_run: run, topic: topic, commit: extra_commit, verdict: "from_discussion", confidence: 0.85, extra: true)
    commit.commit_people.create!(role: "author", raw_name: "Guessed Author", raw_email: "guessed@example.com",
                                 source: "llm", confidence: 0.9)
    commit.commit_people.create!(role: "reviewer", raw_name: "Guessed Reviewer", raw_email: "reviewer@example.com",
                                 source: "llm", confidence: 0.8)
    commit.commit_people.create!(role: "reviewer", raw_name: "Neil Committer", raw_email: "neil@example.com", source: "committer")
    create(:commit_topic, topic: topic, commit: trailer_commit)
    trailer_commit.commit_people.create!(role: "reviewer", raw_name: "Tess Committer", raw_email: "tess@example.com", source: "committer")
  end

  it "groups the story into chapters for long threads" do
    old = create(:message, topic: topic, created_at: 400.days.ago)
    59.times { |i| create(:message, topic: topic, created_at: 300.days.ago + i.hours) }
    run.update!(story: "early [msg:#{old.id}]\n\nlater [msg:#{m2.id}] in [commit:#{'d' * 40}]\n")
    create(:commit_topic, topic: topic, commit: extra_commit, source: "llm", confidence: 0.9)

    get story_topic_path(topic)
    doc = Nokogiri::HTML(response.body)
    chapters = doc.css("details.story-chapter")
    expect(chapters.size).to eq(2)
    expect(chapters.map { |c| c["open"] }.compact.size).to eq(2)
    expect(chapters.first.at_css("summary").text).to include("1 entry")
    expect(chapters.last.css(".story-dot.is-revert, .story-dot.is-commit").size).to eq(1)
    expect(doc.at_css(".modal-side")).to be_nil
  end

  it "shows lineage, verdicts and the LLM badges" do
    get story_topic_path(topic)
    expect(response.body).to include("model-written")
    expect(response.body).to include("run #{run.id}")
    expect(response.body).to include("<li>v1 then v2 landed as c</li><li>then a fixup followed</li>")
    expect(response.body).to include("Commit-by-commit LLM analysis is in the Commits dialog.")
    expect(response.body).not_to include("Matched commits")
    expect(response.body).not_to include("Land the thing")
    expect(response.body).not_to include("commit-llm")
    expect(response.body).not_to include("lineage-verdict")
    expect(response.body).not_to include("Alice")

    create(:commit_topic, topic: topic, commit: pending_commit)
    get commits_details_topic_path(topic)
    doc = Nokogiri::HTML(response.body)
    rows = doc.css(".commit-row")
    land = rows.find { |r| r.text.include?("Land the thing") }
    block = land.at_css("details.commit-llm")
    expect(block["open"]).to be_nil
    summary = block.at_css("summary")
    expect(summary.at_css(".commit-llm-verdict").text).to eq("modified before commit")
    expect(summary.at_css(".commit-llm-change").text).to eq("moderate changes")
    expect(summary.at_css(".commit-llm-change")["title"]).to include("moderate = local logic")
    expect(summary.at_css(".commit-llm-source").text).to eq("from patchset #2")
    expect(summary.at_css(".commit-llm-source a")["href"]).to eq("#message-#{m2.id}")
    expect(summary.at_css(".commit-llm-reviews").text).to eq("3 of 4 reviewers saw the final version")
    badge = summary.at_css(".commit-llm-confidence")
    expect(badge.text).to eq("LLM analysis, 90% sure")
    expect(badge["title"]).to eq("How sure the LLM analysis is about this match")
    expect(block.at_css(".commit-llm-evidence").inner_html).to include(%(hunks from <a href="#message-#{m2.id}">#2</a> with a renamed helper))
    reviewers = block.css(".commit-llm-reviewers li")
    expect(reviewers.map { |li| li.at_css(".commit-llm-reviewer").text }).to eq([ "Alice", "Bob", "Guessed Reviewer", "Neil Committer" ])
    expect(reviewers.map { |li| li.at_css(".commit-llm-coverage").text }).to eq([ "saw the final version", "saw an earlier version", "saw the final version", "saw the final version" ])
    expect(reviewers[0].at_css(".commit-llm-src")).to be_nil
    expect(reviewers[0].inner_html).to include(%(looked at <a href="#message-#{m2.id}">#2</a>))
    expect(reviewers[1].at_css(".commit-llm-src").text).to eq("trailer")
    llm = reviewers[2].at_css(".commit-llm-src")
    expect(llm.text).to eq("LLM analysis, 80% sure")
    expect(llm["title"]).to eq("Found by LLM analysis, not a Reviewed-by trailer")
    neil = reviewers[3].at_css(".commit-llm-src")
    expect(neil.text).to eq("committer")
    expect(neil["title"]).to eq("Committed the patch, counted as its reviewer")
    pending = rows.find { |r| r.text.include?("Still undecided") }
    expect(pending.at_css(".commit-llm-verdict").text).to eq("undecided")
    expect(pending.at_css(".commit-llm-reviews")).to be_nil
    trailer = rows.find { |r| r.text.include?("Trailer-linked thing") }
    expect(trailer.at_css(".commit-llm")).to be_nil
    expect(response.body).not_to include("Unrelated overlap")

    expect(response.body).to include("commit-sidebar-llm")
    expect(land.at_css(".commit-sidebar-llm")["title"]).to eq("Linked to this thread by LLM analysis, no commit trailer")
    expect(response.body).to include("Guessed Author")
    expect(response.body).to include('<span class="commit-credit-llm" title="Credited by LLM analysis, not a commit trailer">LLM</span>')
    expect(response.body).to include("Neil Committer").and include("Tess Committer")
    credit_rows = Nokogiri::HTML(response.body).css(".commit-credit-row")
    neil = credit_rows.find { |row| row.text.include?("Neil Committer") }
    expect(neil.at_css(".commit-credit-name, .commit-credit-link").next_element["class"]).to eq("commit-credit-committer")
    guessed = credit_rows.find { |row| row.text.include?("Guessed Reviewer") }
    expect(guessed.at_css(".commit-credit-llm")["title"]).to eq("Credited by LLM analysis, not a commit trailer")

    get topic_path(topic)
    expect(response.body).to include("Patch story")

    get patchsets_details_topic_path(topic)
    cell = Nokogiri::HTML(response.body).css(".patchset-lineage").find { |c| c.text.include?("rebase") }
    expect(cell.at_css(".patchset-step").text.squish).to eq("rebase of #1")
    expect(cell.at_css(".patchset-step a")["href"]).to eq("#message-#{m1.id}")
    expect(cell.at_css(".patchset-llm").text).to eq("LLM analysis, 85% sure")
    expect(cell.at_css(".patchset-llm")["title"]).to eq("LLM analysis: how sure it is about this step")
    expect(cell["title"]).to eq("same hunks")
  end
end
