require "rails_helper"

RSpec.describe Lineage::ResultIngestor do
  let(:topic) { create(:topic) }
  let(:m1) { create(:message, topic: topic, is_patch_submission: true, created_at: 2.days.ago) }
  let(:m2) { create(:message, topic: topic, is_patch_submission: true, created_at: 1.day.ago) }
  let(:commit) { create(:commit) }
  let(:run) { create(:patchset_run, topic: topic, status: "running", started_at: 1.minute.ago, finished_at: nil) }
  let(:index) do
    { "patchsets" => [ { "message_id" => m1.id }, { "message_id" => m2.id } ],
      "candidates" => [ { "sha" => commit.sha } ] }
  end

  def answer(verdict: "as_is", confidence: 0.9, sha: commit.sha, lineage: nil)
    { "lineage" => lineage || [
        { "message_id" => m1.id, "parent_message_id" => nil, "step_kind" => "new_series", "confidence" => 0.95, "reason" => "first" },
        { "message_id" => m2.id, "parent_message_id" => m1.id, "step_kind" => "rebase", "confidence" => 0.8, "reason" => "same hunks" } ],
      "verdicts" => [ { "sha" => sha, "verdict" => verdict, "source_message_id" => m2.id, "confidence" => confidence, "evidence" => "e" } ],
      "story" => [ "v1 then v2", "then commit" ] }
  end

  def ingest(data, **opts)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "result.json")
      File.write(path, JSON.dump(data))
      described_class.new(run: run, index: index, **opts).call(path)
    end
  end

  it "writes rows, story, links above threshold" do
    ingest(answer)
    expect(run.reload.status).to eq("done")
    expect(run.story).to eq("v1 then v2\nthen commit")
    expect(run.lineages.count).to eq(2)
    expect(run.lineages.find_by(message_id: m2.id).parent_message_id).to eq(m1.id)
    expect(run.verdicts.first.verdict).to eq("as_is")
    link = CommitTopic.find_by(commit_id: commit.id, topic_id: topic.id)
    expect(link.source).to eq("llm")
    expect(link.confidence).to eq(0.9)
  end

  it "does not link below threshold and removes a stale llm link" do
    create(:commit_topic, commit: commit, topic: topic, source: "llm", confidence: 0.9)
    ingest(answer(confidence: 0.5))
    expect(CommitTopic.where(commit_id: commit.id, topic_id: topic.id)).to be_empty
  end

  it "leaves trailer links alone" do
    create(:commit_topic, commit: commit, topic: topic)
    ingest(answer(verdict: "as_is", confidence: 0.9))
    rows = CommitTopic.where(commit_id: commit.id, topic_id: topic.id)
    expect(rows.count).to eq(1)
    expect(rows.first.source).to eq("trailer")
    expect(rows.first.confidence).to be_nil
  end

  it "replaces rows when re-ingesting the same run" do
    2.times { ingest(answer) }
    expect(run.lineages.count).to eq(2)
    expect(run.verdicts.count).to eq(1)
  end

  it "removes a stale llm link for a commit outside the index" do
    other = create(:commit)
    create(:commit_topic, commit: other, topic: topic, source: "llm", confidence: 0.9)
    ingest(answer)
    expect(CommitTopic.where(commit_id: other.id)).to be_empty
  end

  it "keeps backport llm links with a committed canonical and drops them with a rejected one" do
    backport = create(:commit, cherry_picked_from_sha: commit.sha)
    index["candidates"][0]["backports"] = [ backport.sha ]
    create(:commit_topic, commit: commit, topic: topic, source: "llm", confidence: 0.9)
    create(:commit_topic, commit: backport, topic: topic, source: "llm", confidence: 0.9)
    ingest(answer)
    expect(CommitTopic.llm.where(topic_id: topic.id).pluck(:commit_id)).to match_array([ commit.id, backport.id ])
    ingest(answer(verdict: "not_this_thread"))
    expect(CommitTopic.llm.where(topic_id: topic.id)).to be_empty
  end

  it "links the canonical only, never its backports" do
    backport = create(:commit, cherry_picked_from_sha: commit.sha)
    index["candidates"][0]["backports"] = [ backport.sha ]
    ingest(answer)
    expect(CommitTopic.llm.where(topic_id: topic.id).pluck(:commit_id)).to eq([ commit.id ])
  end

  describe "author attribution" do
    def llm_authors(c = commit) = CommitPerson.llm.where(commit_id: c.id, role: "author")

    it "credits the source patchset sender as author with the verdict confidence" do
      ingest(answer(verdict: "modified", confidence: 0.85).tap { |d| d["verdicts"][0]["change_level"] = "light" })
      row = llm_authors.sole
      expect(row).to have_attributes(person_id: m2.sender_person_id, raw_name: m2.sender.name,
                                     raw_email: m2.sender.email, confidence: 0.85)
    end

    it "credits extras too and skips backports" do
      found = create(:commit)
      backport = create(:commit, cherry_picked_from_sha: commit.sha)
      index["candidates"][0]["backports"] = [ backport.sha ]
      ingest(answer.merge("extra_commits" => [ extra(found.sha) ]))
      expect(llm_authors(found).count).to eq(1)
      expect(llm_authors(backport)).to be_empty
    end

    it "skips a commit with a parsed author" do
      create(:commit_person, commit: commit, role: "author", source: "parsed")
      ingest(answer)
      expect(llm_authors).to be_empty
      expect(CommitPerson.parsed.where(commit_id: commit.id).count).to eq(1)
    end

    it "replaces its rows on re-ingest" do
      ingest(answer)
      ingest(answer(confidence: 0.95))
      expect(llm_authors.pluck(:confidence)).to eq([ 0.95 ])
      ingest(answer(confidence: 0.5))
      expect(llm_authors).to be_empty
    end

    it "drops the row of a commit an earlier run linked and this one left out" do
      other = create(:commit)
      create(:commit_topic, commit: other, topic: topic, source: "llm", confidence: 0.9)
      create(:commit_person, commit: other, role: "author", source: "llm", confidence: 0.9)
      ingest(answer)
      expect(llm_authors(other)).to be_empty
      expect(llm_authors.count).to eq(1)
    end

    def authored(author_name: nil, author_message_id: nil)
      answer(verdict: "modified", confidence: 0.85).tap do |d|
        d["verdicts"][0].merge!("change_level" => "light", "author_name" => author_name, "author_message_id" => author_message_id)
      end
    end

    it "prefers the sender of author_message_id over the patchset sender" do
      reply = create(:message, topic: topic, created_at: 12.hours.ago)
      ingest(authored(author_name: "Someone", author_message_id: reply.id))
      expect(llm_authors.sole).to have_attributes(person_id: reply.sender_person_id, raw_name: reply.sender.name,
                                                  raw_email: reply.sender.email, confidence: 0.85)
      expect(run.reload.verdicts.first).to have_attributes(author_name: "Someone", author_message_id: reply.id)
    end

    it "resolves a bare author_name among the topic senders, case-insensitively" do
      carol = create(:alias, name: "Carol Contributor", email: "carol@example.org")
      create(:message, topic: topic, sender_alias: carol, created_at: 12.hours.ago)
      ingest(authored(author_name: " carol contributor "))
      expect(llm_authors.sole).to have_attributes(person_id: carol.person_id, raw_name: "Carol Contributor",
                                                  raw_email: "carol@example.org")
      expect(run.reload.verdicts.first.author_name).to eq("carol contributor")
    end

    it "resolves a name that only matches the sender's display alias" do
      person = create(:person)
      display = create(:alias, person: person, name: "Tom Lane", email: "tgl@example.org")
      raw = create(:alias, person: person, name: "Tom Lane (PostgreSQL)")
      create(:message, topic: topic, sender_alias: raw, created_at: 12.hours.ago)
      ingest(authored(author_name: "Tom Lane"))
      expect(llm_authors.sole).to have_attributes(person_id: person.id, raw_name: "Tom Lane", raw_email: display.email)
    end

    it "writes the raw name with no person when the name matches nobody or several people" do
      ingest(authored(author_name: "Dan Drifter"))
      expect(llm_authors.sole).to have_attributes(person_id: nil, raw_name: "Dan Drifter", raw_email: nil)

      2.times { create(:message, topic: topic, sender_alias: create(:alias, name: "Twin Name")) }
      ingest(authored(author_name: "Twin Name"))
      expect(llm_authors.sole).to have_attributes(person_id: nil, raw_name: "Twin Name", raw_email: nil)
    end

    it "falls back to the patchset sender when both author fields are null" do
      ingest(authored)
      expect(llm_authors.sole).to have_attributes(person_id: m2.sender_person_id, raw_name: m2.sender.name)
      expect(run.reload.verdicts.first).to have_attributes(author_name: nil, author_message_id: nil)
    end

    it "rejects an author_message_id outside the topic and a blank author_name" do
      stranger = create(:message)
      expect { ingest(authored(author_message_id: stranger.id)) }.to raise_error(described_class::Error, /unknown author_message_id/)
      run.update!(status: "running", error: nil)
      expect { ingest(authored(author_name: " ")) }.to raise_error(described_class::Error, /bad author_name/)
      expect(run.reload.status).to eq("failed")
      expect(llm_authors).to be_empty
    end

    it "writes nothing below threshold, for an unnamed from_discussion, or without linking" do
      ingest(answer(confidence: 0.7))
      expect(llm_authors).to be_empty

      data = answer(verdict: "from_discussion")
      data["verdicts"][0]["source_message_id"] = nil
      ingest(data)
      expect(llm_authors).to be_empty

      ingest(answer, link: false)
      expect(llm_authors).to be_empty
    end

    it "credits a from_discussion commit to the author the model named" do
      reply = create(:message, topic: topic, created_at: 12.hours.ago)
      data = answer(verdict: "from_discussion")
      data["verdicts"][0].merge!("source_message_id" => nil, "author_message_id" => reply.id)
      ingest(data)
      expect(llm_authors.sole).to have_attributes(person_id: reply.sender_person_id, raw_name: reply.sender.name, confidence: 0.9)

      data["verdicts"][0].merge!("author_message_id" => nil, "author_name" => "Dan Drifter")
      ingest(data)
      expect(llm_authors.sole).to have_attributes(person_id: nil, raw_name: "Dan Drifter")
    end
  end

  it "fails the run on malformed payloads" do
    base = answer["lineage"]
    bad = {
      "non-hash entry" => [ 1 ],
      "duplicate id" => [ base[0], base[0], base[1] ],
      "unknown parent" => [ base[0], base[1].merge("parent_message_id" => 0) ],
      "self parent" => [ base[0], base[1].merge("parent_message_id" => m2.id) ],
      "bad step_kind" => [ base[0], base[1].merge("step_kind" => "bogus") ],
      "bad confidence" => [ base[0], base[1].merge("confidence" => 1.5) ]
    }
    bad.each do |name, lineage|
      run.update!(status: "running", error: nil)
      expect { ingest(answer(lineage: lineage)) }.to raise_error(described_class::Error), name
      expect(run.reload.status).to eq("failed"), name
      expect(run.lineages.count).to eq(0), name
    end
  end

  it "rejects missing and non-json result files" do
    obj = described_class.new(run: run, index: index)
    expect { obj.call("/nonexistent/result.json") }.to raise_error(described_class::Error, /missing/)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "r.json")
      File.write(path, "not json")
      expect { obj.call(path) }.to raise_error(described_class::Error, /not JSON/)
    end
  end

  it "rejects unknown shas and writes nothing" do
    expect { ingest(answer(sha: "f" * 40)) }.to raise_error(described_class::Error, /unknown sha/)
    expect(run.reload.status).to eq("failed")
    expect(run.error).to include("unknown sha")
    expect(run.lineages.count).to eq(0)
  end

  it "rejects a missing patchset" do
    partial = answer["lineage"].first(1)
    expect { ingest(answer(lineage: partial)) }.to raise_error(described_class::Error, /lineage missing/)
  end

  it "skips linking when asked" do
    ingest(answer, link: false)
    expect(CommitTopic.where(topic_id: topic.id)).to be_empty
    expect(run.reload.status).to eq("done")
  end

  def extra(sha, verdict: "modified", source: m2.id, confidence: 0.9, change_level: "light")
    { "sha" => sha, "verdict" => verdict, "source_message_id" => source, "confidence" => confidence, "evidence" => "git log",
      "change_level" => change_level }
  end

  it "writes extra commits as extra rows and links them" do
    found = create(:commit)
    ingest(answer.merge("extra_commits" => [ extra(found.sha) ]))
    expect(run.reload.status).to eq("done")
    expect(run.error).to be_nil
    rows = run.verdicts.index_by(&:commit_id)
    expect(rows[commit.id].extra).to be(false)
    expect(rows[found.id].extra).to be(true)
    expect(rows[found.id].verdict).to eq("modified")
    link = CommitTopic.find_by(commit_id: found.id, topic_id: topic.id)
    expect(link.source).to eq("llm")
    expect(link.confidence).to eq(0.9)
  end

  it "keeps an llm link for an extra commit across re-ingest" do
    found = create(:commit)
    create(:commit_topic, commit: found, topic: topic, source: "llm", confidence: 0.9)
    ingest(answer.merge("extra_commits" => [ extra(found.sha) ]))
    expect(CommitTopic.where(commit_id: found.id, topic_id: topic.id).count).to eq(1)
  end

  it "drops an extra sha missing from the commits table and notes it" do
    missing = "e" * 40
    ingest(answer.merge("extra_commits" => [ extra(missing) ]))
    expect(run.reload.status).to eq("done")
    expect(run.error).to eq("extra commit not in commits table: #{missing}")
    expect(run.verdicts.count).to eq(1)
    expect(CommitTopic.llm.where(commit_id: commit.id, topic_id: topic.id).count).to eq(1)
  end

  it "ignores an extra that duplicates a candidate and dedupes extras" do
    found = create(:commit)
    extras = [ extra(commit.sha, verdict: "partial"), extra(found.sha), extra(found.sha, verdict: "partial") ]
    ingest(answer.merge("extra_commits" => extras))
    expect(run.reload.verdicts.count).to eq(2)
    expect(run.verdicts.find_by(commit_id: commit.id)).to have_attributes(verdict: "as_is", extra: false)
    expect(run.verdicts.find_by(commit_id: found.id)).to have_attributes(verdict: "modified", extra: true)
  end

  it "links a from_discussion candidate with no source" do
    data = answer(verdict: "from_discussion")
    data["verdicts"][0]["source_message_id"] = nil
    ingest(data)
    expect(run.reload.verdicts.first).to have_attributes(verdict: "from_discussion", source_message_id: nil)
    expect(CommitTopic.llm.where(commit_id: commit.id, topic_id: topic.id).count).to eq(1)
  end

  it "writes origin from the index, trailer when absent, extra for extras" do
    found = create(:commit)
    index["candidates"][0]["origin"] = "overlap"
    ingest(answer.merge("extra_commits" => [ extra(found.sha) ]))
    expect(run.verdicts.find_by(commit_id: commit.id).origin).to eq("overlap")
    expect(run.verdicts.find_by(commit_id: found.id).origin).to eq("extra")

    index["candidates"][0].delete("origin")
    ingest(answer)
    expect(run.verdicts.find_by(commit_id: commit.id).origin).to eq("trailer")
  end

  it "requires change_level for modified and partial only" do
    cases = {
      "modified without level" => [ "modified", nil ],
      "partial with bogus level" => [ "partial", "huge" ],
      "as_is with level" => [ "as_is", "light" ],
      "from_discussion with level" => [ "from_discussion", "moderate" ]
    }
    cases.each do |name, (verdict, level)|
      run.update!(status: "running", error: nil)
      data = answer(verdict: verdict)
      data["verdicts"][0]["change_level"] = level
      expect { ingest(data) }.to raise_error(described_class::Error, /change_level/), name
      expect(run.reload.status).to eq("failed"), name
    end
    found = create(:commit)
    expect { ingest(answer.merge("extra_commits" => [ extra(found.sha, change_level: nil) ])) }.to raise_error(described_class::Error, /change_level/)
  end

  it "stores change_level for modified verdicts and nil otherwise" do
    data = answer(verdict: "modified")
    data["verdicts"][0]["change_level"] = "significant"
    ingest(data)
    expect(run.reload.verdicts.first.change_level).to eq("significant")
    ingest(answer)
    expect(run.reload.verdicts.first.change_level).to be_nil
  end

  it "writes empty reviews and zero counts for a candidate without reviewers" do
    ingest(answer)
    expect(run.reload.verdicts.first).to have_attributes(reviews: [], reviewers_final: 0, reviewers_earlier: 0, reviewers_none: 0)
  end

  def review(name, coverage: "final", ids: nil, note: "looked at it")
    { "reviewer" => name, "reviewed_message_ids" => ids || [ m2.id ], "coverage" => coverage, "note" => note }
  end

  def suggestion(name, message: nil, coverage: "final", ids: nil, confidence: 0.9, note: "found a bug")
    { "reviewer" => name, "reviewer_message_id" => message, "reviewed_message_ids" => ids || [ m2.id ],
      "coverage" => coverage, "confidence" => confidence, "note" => note }
  end

  it "matches reviewers to trailers, drops strangers, pads the rest as not assessed" do
    index["candidates"][0]["reviewers"] = [ "Alice Smith", "Bob Jones", "Dan Hill" ]
    data = answer
    data["verdicts"][0]["reviews"] = [ review("alice smith"), review("Carol King"), review("DAN HILL", coverage: "earlier", ids: [ m1.id ]),
                                       review("Alice Smith", coverage: "none") ]
    ingest(data)
    row = run.reload.verdicts.first
    expect(row.reviews).to eq([
      { "reviewer" => "Alice Smith", "reviewed_message_ids" => [ m2.id ], "coverage" => "final", "note" => "looked at it", "source" => "trailer" },
      { "reviewer" => "Bob Jones", "reviewed_message_ids" => [], "coverage" => "none", "note" => "not assessed", "source" => "trailer" },
      { "reviewer" => "Dan Hill", "reviewed_message_ids" => [ m1.id ], "coverage" => "earlier", "note" => "looked at it", "source" => "trailer" }
    ])
    expect(row).to have_attributes(reviewers_final: 1, reviewers_earlier: 1, reviewers_none: 1)
    expect(run.error).to eq("reviewer not in trailers: Carol King for #{commit.sha}")
  end

  it "counts a committer credited as reviewer as final whatever the model said" do
    index["candidates"][0].merge!("reviewers" => [ "Alice Smith", "Bob Jones" ], "committer_reviewers" => [ "Alice Smith" ])
    data = answer
    data["verdicts"][0]["reviews"] = [ review("Alice Smith", coverage: "none", ids: [], note: "silent in the thread"),
                                       review("Bob Jones", coverage: "earlier", ids: [ m1.id ]) ]
    ingest(data)
    row = run.reload.verdicts.first
    expect(row.reviews).to eq([
      { "reviewer" => "Alice Smith", "reviewed_message_ids" => [ m2.id ], "coverage" => "final", "note" => "committed the patch; silent in the thread", "source" => "trailer" },
      { "reviewer" => "Bob Jones", "reviewed_message_ids" => [ m1.id ], "coverage" => "earlier", "note" => "looked at it", "source" => "trailer" }
    ])
    expect(row).to have_attributes(reviewers_final: 1, reviewers_earlier: 1, reviewers_none: 0)
  end

  it "drops reviews on extras with a note" do
    found = create(:commit)
    ex = extra(found.sha).merge("reviews" => [ review("Someone Else") ])
    ingest(answer.merge("extra_commits" => [ ex ]))
    row = run.verdicts.find_by(commit_id: found.id)
    expect(row.reviews).to eq([])
    expect(row.reviewers_final).to eq(0)
    expect(run.reload.error).to eq("reviews ignored for extra #{found.sha}: no trailer reviewers, use suggested_reviews")
  end

  it "rejects malformed reviews" do
    index["candidates"][0]["reviewers"] = [ "Alice Smith" ]
    bad = {
      "not an array" => "nope",
      "non-hash entry" => [ 1 ],
      "blank reviewer" => [ review("") ],
      "bad coverage" => [ review("Alice Smith", coverage: "partial") ],
      "unknown message" => [ review("Alice Smith", ids: [ 0 ]) ],
      "ids not an array" => [ review("Alice Smith", ids: m2.id) ]
    }
    bad.each do |name, reviews|
      run.update!(status: "running", error: nil)
      data = answer
      data["verdicts"][0]["reviews"] = reviews
      expect { ingest(data) }.to raise_error(described_class::Error), name
      expect(run.reload.status).to eq("failed"), name
      expect(run.verdicts.count).to eq(0), name
    end
  end

  it "normalizes message and commit references in stored text" do
    index["candidates"][0]["reviewers"] = [ "Alice Smith" ]
    other = create(:commit)
    data = answer
    data["lineage"][1]["reason"] = "rebased per messages/1.txt"
    data["verdicts"][0]["evidence"] = "see message #{m1.id} and #{other.sha}, also #{commit.sha}"
    data["verdicts"][0]["reviews"] = [ review("Alice Smith", note: "in message #{m2.id}") ]
    data["story"] = [ " ends in #{commit.sha} ", "", "after [msg:#{m1.id}]" ]
    ingest(data)
    run.reload
    expect(run.lineages.find_by(message_id: m2.id).reason).to eq("rebased per [msg:#{m1.id}]")
    expect(run.verdicts.first.evidence).to eq("see [msg:#{m1.id}] and [commit:#{other.sha}], also [commit:#{commit.sha}]")
    expect(run.verdicts.first.reviews.first["note"]).to eq("in [msg:#{m2.id}]")
    expect(run.story).to eq("ends in [commit:#{commit.sha}]\nafter [msg:#{m1.id}]")
    expect(run.raw_result["story"]).to eq(data["story"])
  end

  it "still takes a string story from an older bundle" do
    data = answer
    data["story"] = "v1 then commit"
    ingest(data)
    expect(run.reload.story).to eq("v1 then commit")
  end

  it "rejects a story that is neither a string nor strings" do
    data = answer
    data["story"] = [ "ok", 3 ]
    expect { ingest(data) }.to raise_error(described_class::Error, /story/)
  end

  it "rejects verdicts and extra commits in lineage mode" do
    found = create(:commit)
    expect { ingest(answer, mode: "lineage") }.to raise_error(described_class::Error, /lineage mode/)
    expect(run.reload.status).to eq("failed")

    run.update!(status: "running", error: nil)
    data = answer.merge("verdicts" => [], "extra_commits" => [ extra(found.sha) ])
    expect { ingest(data, mode: "lineage") }.to raise_error(described_class::Error, /lineage mode/)
    expect(run.reload.status).to eq("failed")
    expect(run.verdicts.count).to eq(0)

    run.update!(status: "running", error: nil)
    ingest(answer.merge("verdicts" => [], "extra_commits" => []), mode: "lineage")
    expect(run.reload.status).to eq("done")
  end

  it "keeps llm links and authors on a lineage-only ingest" do
    create(:commit_topic, commit: commit, topic: topic, source: "llm", confidence: 0.9)
    create(:commit_person, commit: commit, role: "author", source: "llm", confidence: 0.9)
    ingest(answer.merge("verdicts" => [], "extra_commits" => []), mode: "lineage")
    expect(run.reload.status).to eq("done")
    expect(CommitTopic.llm.where(commit_id: commit.id, topic_id: topic.id).count).to eq(1)
    expect(CommitPerson.llm.where(commit_id: commit.id, role: "author").count).to eq(1)
  end

  it "rejects malformed extras" do
    found = create(:commit)
    bad = {
      "not an array" => "nope",
      "non-hash entry" => [ 1 ],
      "bad verdict" => [ extra(found.sha, verdict: "not_this_thread") ],
      "bad sha" => [ extra(nil) ],
      "unknown source" => [ extra(found.sha, source: 0) ],
      "bad confidence" => [ extra(found.sha, confidence: 2) ]
    }
    bad.each do |name, extras|
      run.update!(status: "running", error: nil)
      expect { ingest(answer.merge("extra_commits" => extras)) }.to raise_error(described_class::Error), name
      expect(run.reload.status).to eq("failed"), name
      expect(run.verdicts.count).to eq(0), name
    end
  end

  describe "suggested reviewers" do
    it "stores them as llm rows, dedupes by name, normalizes notes and counts them" do
      data = answer
      data["verdicts"][0]["suggested_reviews"] = [
        suggestion(" Carol King "), suggestion("carol  king", coverage: "earlier"),
        suggestion("Dan Hill", coverage: "earlier", ids: [ m1.id ], confidence: 0.6, note: "tested message #{m1.id}") ]
      ingest(data)
      row = run.reload.verdicts.first
      expect(row.reviews).to eq([
        { "reviewer" => "Carol King", "reviewed_message_ids" => [ m2.id ], "coverage" => "final", "note" => "found a bug",
          "source" => "llm", "reviewer_message_id" => nil, "confidence" => 0.9 },
        { "reviewer" => "Dan Hill", "reviewed_message_ids" => [ m1.id ], "coverage" => "earlier", "note" => "tested [msg:#{m1.id}]",
          "source" => "llm", "reviewer_message_id" => nil, "confidence" => 0.6 } ])
      expect(row).to have_attributes(reviewers_final: 1, reviewers_earlier: 1, reviewers_none: 0)
      expect(run.error).to be_nil
    end

    it "ignores them on a commit with trailer reviewers or a rejected verdict, with a note" do
      index["candidates"][0]["reviewers"] = [ "Alice Smith" ]
      data = answer
      data["verdicts"][0]["reviews"] = [ review("Alice Smith") ]
      data["verdicts"][0]["suggested_reviews"] = [ suggestion("Carol King") ]
      ingest(data)
      expect(run.reload.verdicts.first.reviews.map { |r| r["reviewer"] }).to eq([ "Alice Smith" ])
      expect(run.error).to eq("suggested reviewers ignored for #{commit.sha}: has trailer reviewers")

      index["candidates"][0].delete("reviewers")
      data = answer(verdict: "not_this_thread")
      data["verdicts"][0]["suggested_reviews"] = [ suggestion("Carol King") ]
      ingest(data)
      expect(run.reload.verdicts.first.reviews).to eq([])
      expect(run.error).to eq("suggested reviewers ignored for #{commit.sha}: verdict not_this_thread")
    end

    it "takes them on extras" do
      found = create(:commit)
      ex = extra(found.sha).merge("suggested_reviews" => [ suggestion("Someone Else") ])
      ingest(answer.merge("extra_commits" => [ ex ]))
      row = run.verdicts.find_by(commit_id: found.id)
      expect(row.reviews.sole).to include("reviewer" => "Someone Else", "source" => "llm")
      expect(row.reviewers_final).to eq(1)
      expect(run.reload.error).to be_nil
    end

    it "takes suggestions on an extra that also sent reviews" do
      found = create(:commit)
      ex = extra(found.sha).merge("reviews" => [ review("Someone Else") ], "suggested_reviews" => [ suggestion("Someone Else") ])
      ingest(answer.merge("extra_commits" => [ ex ]))
      row = run.verdicts.find_by(commit_id: found.id)
      expect(row.reviews.sole).to include("reviewer" => "Someone Else", "source" => "llm")
      expect(run.reload.error).to eq("reviews ignored for extra #{found.sha}: no trailer reviewers, use suggested_reviews")
    end

    it "fails on a malformed list even where it would be dropped" do
      data = answer(verdict: "not_this_thread")
      data["verdicts"][0]["suggested_reviews"] = [ suggestion("Carol King", coverage: "none") ]
      expect { ingest(data) }.to raise_error(described_class::Error, /coverage/)
      expect(run.reload.status).to eq("failed")
    end

    it "rejects malformed entries" do
      stranger = create(:message)
      bad = {
        "not an array" => "nope",
        "non-hash entry" => [ 1 ],
        "blank reviewer" => [ suggestion(" ") ],
        "coverage none" => [ suggestion("Carol King", coverage: "none") ],
        "unknown reviewer message" => [ suggestion("Carol King", message: stranger.id) ],
        "unknown reviewed message" => [ suggestion("Carol King", ids: [ 0 ]) ],
        "ids not an array" => [ suggestion("Carol King", ids: m2.id) ],
        "bad confidence" => [ suggestion("Carol King", confidence: 1.5) ]
      }
      bad.each do |name, list|
        run.update!(status: "running", error: nil)
        data = answer
        data["verdicts"][0]["suggested_reviews"] = list
        expect { ingest(data) }.to raise_error(described_class::Error), name
        expect(run.reload.status).to eq("failed"), name
        expect(run.verdicts.count).to eq(0), name
      end
      run.update!(status: "running", error: nil)
      found = create(:commit)
      ex = extra(found.sha).merge("suggested_reviews" => [ suggestion("Carol King", coverage: "none") ])
      expect { ingest(answer.merge("extra_commits" => [ ex ])) }.to raise_error(described_class::Error, /coverage/)
    end

    describe "commit_people rows" do
      def llm_reviewers(c = commit) = CommitPerson.llm.where(commit_id: c.id, role: "reviewer")

      def suggested(*entries, verdict: "as_is", confidence: 0.9)
        answer(verdict: verdict, confidence: confidence).tap { |d| d["verdicts"][0]["suggested_reviews"] = entries }
      end

      it "credits the sender of reviewer_message_id with the entry confidence" do
        reply = create(:message, topic: topic, created_at: 12.hours.ago)
        ingest(suggested(suggestion("Whoever", message: reply.id, confidence: 0.85)))
        expect(llm_reviewers.sole).to have_attributes(person_id: reply.sender_person_id, raw_name: reply.sender.name,
                                                      raw_email: reply.sender.email, confidence: 0.85)
      end

      it "resolves a bare name among the senders, else keeps the raw name" do
        carol = create(:alias, name: "Carol King", email: "carol@example.org")
        create(:message, topic: topic, sender_alias: carol, created_at: 12.hours.ago)
        ingest(suggested(suggestion(" carol king "), suggestion("Dan Drifter")))
        rows = llm_reviewers.order(:id).to_a
        expect(rows.first).to have_attributes(person_id: carol.person_id, raw_name: "Carol King", raw_email: "carol@example.org")
        expect(rows.last).to have_attributes(person_id: nil, raw_name: "Dan Drifter", raw_email: nil)
      end

      it "writes nothing below either threshold, on a rejected verdict, or without linking" do
        ingest(suggested(suggestion("Carol King", confidence: 0.7)))
        expect(llm_reviewers).to be_empty
        ingest(suggested(suggestion("Carol King"), confidence: 0.7))
        expect(llm_reviewers).to be_empty
        ingest(suggested(suggestion("Carol King"), verdict: "not_this_thread"))
        expect(llm_reviewers).to be_empty
        ingest(suggested(suggestion("Carol King")), link: false)
        expect(llm_reviewers).to be_empty
      end

      it "skips anyone with a parsed credit on the commit" do
        reply = create(:message, topic: topic, created_at: 12.hours.ago)
        create(:commit_person, commit: commit, role: "author", source: "parsed", person: Person.find(reply.sender_person_id), raw_name: "S. Body")
        create(:commit_person, commit: commit, role: "committer", source: "parsed", person: nil, raw_name: "Dan Hill")
        create(:commit_person, commit: commit, role: "tested_by", source: "parsed", person: nil, raw_name: "Tess Tester")
        ingest(suggested(suggestion("Somebody", message: reply.id), suggestion("dan hill"), suggestion("tess tester"), suggestion("Carol King")))
        expect(llm_reviewers.pluck(:raw_name)).to eq([ "Carol King" ])
      end

      it "does not credit the llm author as reviewer too" do
        data = suggested(suggestion("Patch Sender", message: m2.id), verdict: "modified")
        data["verdicts"][0]["change_level"] = "light"
        ingest(data)
        expect(CommitPerson.llm.where(commit_id: commit.id).pluck(:role)).to eq([ "author" ])
      end

      it "keeps the higher confidence when two names resolve to the same person" do
        reply = create(:message, topic: topic, created_at: 12.hours.ago)
        ingest(suggested(suggestion("Carol King", message: reply.id, confidence: 0.85),
                         suggestion("C. King", message: reply.id, confidence: 0.95)))
        expect(llm_reviewers.sole).to have_attributes(person_id: reply.sender_person_id, confidence: 0.95)
      end

      it "replaces its rows on re-ingest and drops rows of commits an earlier run linked" do
        other = create(:commit)
        create(:commit_topic, commit: other, topic: topic, source: "llm", confidence: 0.9)
        create(:commit_person, commit: other, role: "reviewer", source: "llm", confidence: 0.9)
        ingest(suggested(suggestion("Carol King", confidence: 0.85)))
        ingest(suggested(suggestion("Carol King", confidence: 0.95)))
        expect(llm_reviewers.pluck(:confidence)).to eq([ 0.95 ])
        expect(llm_reviewers(other)).to be_empty
      end

      it "credits reviewers of extra commits" do
        found = create(:commit)
        ex = extra(found.sha).merge("suggested_reviews" => [ suggestion("Someone Else") ])
        ingest(answer.merge("extra_commits" => [ ex ]))
        expect(llm_reviewers(found).sole).to have_attributes(raw_name: "Someone Else", confidence: 0.9)
      end
    end
  end

  describe "committer as reviewer" do
    let(:committer_person) { create(:person) }

    before do
      create(:commit_person, commit: commit, role: "committer", person: committer_person, raw_name: "Neil Conway", raw_email: "neil@example.com")
    end

    def implied = CommitPerson.committer_sourced.where(commit_id: commit.id)

    def modified(**fields)
      answer(verdict: "modified", confidence: 0.9).tap { |d| d["verdicts"][0].merge!("change_level" => "light", **fields) }
    end

    it "credits the committer when the model attributes the patch to someone else" do
      ingest(modified)
      expect(implied.sole).to have_attributes(role: "reviewer", person_id: committer_person.id)
      row = run.reload.verdicts.first
      expect(row.reviews).to eq([ { "reviewer" => "Neil Conway", "reviewed_message_ids" => [ m2.id ], "coverage" => "final",
                                    "note" => "committed the patch", "source" => "committer" } ])
      expect(row.reviewers_final).to eq(1)
    end

    it "writes nothing when the committer is the llm author, and removes a stale row on rerun" do
      ingest(modified)
      expect(implied.count).to eq(1)
      neil = create(:alias, person: committer_person, name: "Neil Conway", email: "neil@example.com")
      reply = create(:message, topic: topic, sender_alias: neil, created_at: 12.hours.ago)
      ingest(modified("author_message_id" => reply.id))
      expect(implied).to be_empty
      expect(run.reload.verdicts.first.reviews).to eq([])
    end

    it "does not double a committer already in the trailer reviewers" do
      index["candidates"][0].merge!("reviewers" => [ "Neil Conway" ], "committer_reviewers" => [ "Neil Conway" ])
      create(:commit_person, commit: commit, role: "reviewer", person: committer_person, raw_name: "Neil Conway", raw_email: "neil@example.com")
      data = modified
      data["verdicts"][0]["reviews"] = [ review("Neil Conway", coverage: "none", ids: [], note: "silent") ]
      ingest(data)
      expect(implied).to be_empty
      row = run.reload.verdicts.first
      expect(row.reviews.map { |r| r["reviewer"] }).to eq([ "Neil Conway" ])
      expect(row.reviews.first["coverage"]).to eq("final")
    end

    it "removes the committer row of a commit a rerun no longer judges" do
      ingest(modified)
      expect(implied.count).to eq(1)
      expect(CommitTopic.llm.where(commit_id: commit.id, topic_id: topic.id)).to exist
      other = create(:commit)
      index["candidates"] << { "sha" => other.sha }
      ingest(answer(sha: other.sha))
      expect(CommitPerson.llm.where(commit_id: commit.id)).to be_empty
      expect(implied).to be_empty
    end

    it "skips the mirror when a suggested reviewer already carries the committer's name" do
      ingest(modified("suggested_reviews" => [ suggestion("Neil Conway") ]))
      row = run.reload.verdicts.first
      expect(row.reviews.map { |r| [ r["reviewer"], r["source"] ] }).to eq([ [ "Neil Conway", "llm" ] ])
      expect(row.reviewers_final).to eq(1)
    end

    it "does not mirror onto a rejected verdict" do
      create(:commit_person, commit: commit, role: "author", person: create(:person), raw_name: "Someone Else", raw_email: "else@example.com")
      ingest(answer(verdict: "not_this_thread"))
      expect(implied.sole).to have_attributes(role: "reviewer", person_id: committer_person.id)
      expect(run.reload.verdicts.first.reviews).to eq([])
    end

    it "writes nothing without linking" do
      ingest(modified, link: false)
      expect(implied).to be_empty
      expect(run.reload.verdicts.first.reviews).to eq([])
    end
  end

  describe "update mode" do
    let(:old_commit) { create(:commit) }
    let(:old_extra) { create(:commit) }
    let(:base) do
      create(:patchset_run, topic: topic, status: "done", mode: "trailer", through_message: m1,
                            raw_result: { "lineage" => [ { "message_id" => m1.id } ], "verdicts" => [ { "sha" => old_commit.sha } ],
                                          "extra_commits" => [ { "sha" => old_extra.sha } ], "story" => [ "old" ] }).tap do |r|
        create(:patchset_lineage, patchset_run: r, message: m1)
        create(:commit_verdict, patchset_run: r, commit: old_commit)
        create(:commit_verdict, patchset_run: r, commit: old_extra, extra: true, origin: "extra")
      end
    end
    let(:index) do
      { "patchsets" => [ { "message_id" => m1.id, "new" => false }, { "message_id" => m2.id, "new" => true } ],
        "candidates" => [ { "sha" => commit.sha, "origin" => "trailer" } ], "base_run_id" => base.id }
    end
    let(:new_lineage) { [ { "message_id" => m2.id, "parent_message_id" => m1.id, "step_kind" => "rebase", "confidence" => 0.8, "reason" => "r" } ] }

    def update_answer(**opts) = answer(lineage: new_lineage, **opts).merge("extra_commits" => [])

    it "carries the base rows forward and merges raw_result" do
      ingest(update_answer, mode: "update")
      expect(run.reload.status).to eq("done")
      expect(run.lineages.pluck(:message_id)).to contain_exactly(m1.id, m2.id)
      expect(run.verdicts.pluck(:commit_id)).to contain_exactly(old_commit.id, old_extra.id, commit.id)
      expect(run.raw_result["lineage"].map { |l| l["message_id"] }).to eq([ m1.id, m2.id ])
      expect(run.raw_result["verdicts"].map { |v| v["sha"] }).to eq([ old_commit.sha, commit.sha ])
      expect(run.raw_result["extra_commits"].map { |v| v["sha"] }).to eq([ old_extra.sha ])
      expect(run.raw_result["story"]).to eq([ "v1 then v2", "then commit" ])
      expect(run.raw_result["update"]["lineage"]).to eq(new_lineage)
    end

    it "leaves old llm links and credits alone" do
      create(:commit_topic, topic: topic, commit: old_extra, source: "llm", confidence: 0.9)
      create(:commit_person, commit: old_extra, role: "author", raw_name: "Old", source: "llm", confidence: 0.9)
      ingest(update_answer, mode: "update")
      expect(CommitTopic.llm.where(topic_id: topic.id).pluck(:commit_id)).to include(old_extra.id)
      expect(CommitPerson.llm.where(commit_id: old_extra.id).count).to eq(1)
    end

    it "drops lineage for an old patchset with a note, still rejects unknown ids" do
      bad = new_lineage + [ { "message_id" => m1.id, "parent_message_id" => nil, "step_kind" => "new_series", "confidence" => 1, "reason" => "r" } ]
      ingest(answer(lineage: bad).merge("extra_commits" => []), mode: "update")
      expect(run.reload.status).to eq("done")
      expect(run.error).to include("lineage for old patchset #{m1.id} dropped")
      expect(run.lineages.pluck(:message_id)).to contain_exactly(m1.id, m2.id)
      expect(run.raw_result["lineage"].map { |l| l["message_id"] }).to eq([ m1.id, m2.id ])

      stranger = new_lineage + [ new_lineage[0].merge("message_id" => create(:message, topic: topic).id) ]
      expect { ingest(answer(lineage: stranger).merge("extra_commits" => []), mode: "update") }
        .to raise_error(described_class::Error, /unknown message id/)
    end

    it "still rejects missing lineage for a new patchset" do
      expect { ingest(answer(lineage: []).merge("extra_commits" => []), mode: "update") }
        .to raise_error(described_class::Error, /lineage missing for message #{m2.id}/)
    end

    it "drops a verdict on a commit the base run judged, still rejects unknown shas" do
      data = update_answer
      data["verdicts"] << data["verdicts"][0].merge("sha" => old_commit.sha)
      ingest(data, mode: "update")
      expect(run.reload.error).to include("verdict for #{old_commit.sha} dropped: judged by the base run")
      expect(run.verdicts.pluck(:commit_id)).to contain_exactly(old_commit.id, old_extra.id, commit.id)
      expect(run.raw_result["verdicts"].map { |v| v["sha"] }).to eq([ old_commit.sha, commit.sha ])

      data = update_answer
      data["verdicts"] << data["verdicts"][0].merge("sha" => create(:commit).sha)
      expect { ingest(data, mode: "update") }.to raise_error(described_class::Error, /unknown sha/)
    end

    it "keeps base rows over new ones for the same patchset or commit" do
      create(:patchset_lineage, patchset_run: base, message: m2, parent_message_id: nil, step_kind: "new_series")
      create(:commit_verdict, patchset_run: base, commit: commit, verdict: "undecided")
      ingest(update_answer, mode: "update")
      expect(run.reload.status).to eq("done")
      expect(run.error).to include("lineage for #{m2.id} dropped: carried", "verdict for #{commit.sha} dropped: carried")
      expect(run.lineages.find_by(message_id: m2.id).step_kind).to eq("new_series")
      expect(run.verdicts.find_by(commit_id: commit.id).verdict).to eq("undecided")
    end

    it "builds an update on top of an update" do
      ingest(update_answer, mode: "update")
      m3 = create(:message, topic: topic, is_patch_submission: true, created_at: 1.hour.ago)
      commit2 = create(:commit)
      run2 = create(:patchset_run, topic: topic, status: "running", mode: "update", started_at: 1.minute.ago, finished_at: nil)
      index2 = { "patchsets" => [ { "message_id" => m1.id, "new" => false }, { "message_id" => m2.id, "new" => false },
                                  { "message_id" => m3.id, "new" => true } ],
                 "candidates" => [ { "sha" => commit2.sha, "origin" => "trailer" } ], "base_run_id" => run.id }
      data = { "lineage" => [ { "message_id" => m3.id, "parent_message_id" => m2.id, "step_kind" => "rebase", "confidence" => 0.8, "reason" => "r" } ],
               "verdicts" => [ { "sha" => commit2.sha, "verdict" => "as_is", "source_message_id" => m3.id, "confidence" => 0.9, "evidence" => "e" } ],
               "extra_commits" => [], "story" => [ "v3" ] }
      Dir.mktmpdir do |dir|
        path = File.join(dir, "result.json")
        File.write(path, JSON.dump(data))
        described_class.new(run: run2, index: index2, mode: "update").call(path)
      end

      run2.reload
      expect(run2.status).to eq("done")
      expect(run2.lineages.pluck(:message_id)).to contain_exactly(m1.id, m2.id, m3.id)
      expect(run2.verdicts.pluck(:commit_id)).to contain_exactly(old_commit.id, old_extra.id, commit.id, commit2.id)
      expect(run2.verdicts.find_by(commit_id: old_extra.id)).to have_attributes(extra: true, origin: "extra")
      expect(run2.raw_result["lineage"].map { |l| l["message_id"] }).to eq([ m1.id, m2.id, m3.id ])
      expect(run2.raw_result["verdicts"].map { |v| v["sha"] }).to eq([ old_commit.sha, commit.sha, commit2.sha ])
      expect(run2.raw_result["extra_commits"].map { |v| v["sha"] }).to eq([ old_extra.sha ])
      expect(run2.raw_result["update"]).to eq(data)
      expect(run.reload.verdicts.count).to eq(3)
    end

    it "rejects a missing candidate verdict" do
      data = update_answer.merge("verdicts" => [])
      expect { ingest(data, mode: "update") }.to raise_error(described_class::Error, /verdict missing for #{commit.sha}/)
    end

    it "rejects extra commits" do
      data = update_answer.merge("extra_commits" => [ { "sha" => create(:commit).sha, "verdict" => "as_is", "confidence" => 1 } ])
      expect { ingest(data, mode: "update") }.to raise_error(described_class::Error, /no extra_commits/)
    end

    it "raises BaseGone without failing the run when the base run is gone" do
      index
      base.destroy!
      expect { ingest(update_answer, mode: "update") }.to raise_error(described_class::BaseGone)
      expect(run.reload.status).to eq("running")
    end
  end

  describe "discussion mode" do
    let(:report) { create(:message, topic: topic, created_at: 3.days.ago) }
    let(:fix) { create(:message, topic: topic, created_at: 2.days.ago) }

    def discussion_answer(**verdict)
      { "lineage" => [], "extra_commits" => [], "story" => [ "fixed inline" ],
        "verdicts" => [ { "sha" => commit.sha, "verdict" => "from_discussion", "source_message_id" => nil,
                          "author_name" => nil, "author_message_id" => nil, "confidence" => 0.9, "evidence" => "inline" }.merge(verdict) ] }
    end

    before { index.replace("patchsets" => [], "candidates" => [ { "sha" => commit.sha, "origin" => "trailer", "reviewers" => [ "Rev" ] } ]) }

    it "moves a message source to the author and clears it" do
      ingest(discussion_answer("source_message_id" => fix.id), mode: "discussion")
      v = run.reload.verdicts.sole
      expect(v).to have_attributes(source_message_id: nil, author_message_id: fix.id)
      expect(run.error).to include("source_message_id #{fix.id} is not a patchset")
      expect(CommitPerson.llm.where(commit_id: commit.id, role: "author").sole.person_id).to eq(fix.sender_person_id)
    end

    it "keeps a named author when clearing the source" do
      ingest(discussion_answer("source_message_id" => fix.id, "author_message_id" => report.id), mode: "discussion")
      expect(run.reload.verdicts.sole).to have_attributes(source_message_id: nil, author_message_id: report.id)
    end

    it "still rejects a source outside the topic, and a message source in other modes" do
      stranger = create(:message)
      expect { ingest(discussion_answer("source_message_id" => stranger.id), mode: "discussion") }
        .to raise_error(described_class::Error, /unknown source_message_id/)
      expect { ingest(discussion_answer("source_message_id" => fix.id), mode: "trailer") }
        .to raise_error(described_class::Error, /unknown source_message_id/)
    end

    it "drops reviewed ids that are not patchsets" do
      data = discussion_answer("reviews" => [ { "reviewer" => "Rev", "reviewed_message_ids" => [ fix.id ], "coverage" => "final", "note" => "n" } ])
      ingest(data, mode: "discussion")
      expect(run.reload.verdicts.sole.reviews.first).to include("reviewer" => "Rev", "reviewed_message_ids" => [], "coverage" => "final")
      expect(run.error).to include("reviewed message #{fix.id} is not a patchset")
      expect { ingest(data, mode: "trailer") }.to raise_error(described_class::Error, /unknown reviewed message/)
    end

    it "drops reviewed ids of suggested reviewers that are not patchsets" do
      index["candidates"][0]["reviewers"] = []
      data = discussion_answer("suggested_reviews" => [ { "reviewer" => "Sug", "reviewer_message_id" => fix.id, "reviewed_message_ids" => [ report.id ],
                                                          "coverage" => "final", "note" => "n", "confidence" => 0.9 } ])
      ingest(data, mode: "discussion")
      expect(run.reload.verdicts.sole.reviews.first).to include("reviewer" => "Sug", "reviewed_message_ids" => [])
    end

    it "validates lineage normally when the bundle has patchsets" do
      index["patchsets"] = [ { "message_id" => m1.id } ]
      expect { ingest(discussion_answer, mode: "discussion") }.to raise_error(described_class::Error, /lineage missing for message #{m1.id}/)
      data = discussion_answer.merge("lineage" => [ { "message_id" => m1.id, "parent_message_id" => nil, "step_kind" => "new_series",
                                                      "confidence" => 0.7, "reason" => "nocfbot" } ])
      ingest(data, mode: "discussion")
      expect(run.reload.lineages.pluck(:message_id)).to eq([ m1.id ])
    end
  end

  it "ingests a discussion run with no patchsets" do
    index.replace("patchsets" => [], "candidates" => [ { "sha" => commit.sha, "origin" => "trailer" } ])
    data = { "lineage" => [], "extra_commits" => [], "story" => [ "fixed inline" ],
             "verdicts" => [ { "sha" => commit.sha, "verdict" => "from_discussion", "source_message_id" => nil,
                               "author_name" => nil, "author_message_id" => nil, "confidence" => 0.9, "evidence" => "inline" } ] }
    ingest(data, mode: "discussion")
    expect(run.reload.status).to eq("done")
    expect(run.verdicts.first.verdict).to eq("from_discussion")
  end
end
