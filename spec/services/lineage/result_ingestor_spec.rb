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
      "story" => "v1 then v2 then commit" }
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
    expect(run.story).to eq("v1 then v2 then commit")
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

  it "matches reviewers to trailers, drops strangers, pads the rest as not assessed" do
    index["candidates"][0]["reviewers"] = [ "Alice Smith", "Bob Jones", "Dan Hill" ]
    data = answer
    data["verdicts"][0]["reviews"] = [ review("alice smith"), review("Carol King"), review("DAN HILL", coverage: "earlier", ids: [ m1.id ]),
                                       review("Alice Smith", coverage: "none") ]
    ingest(data)
    row = run.reload.verdicts.first
    expect(row.reviews).to eq([
      { "reviewer" => "Alice Smith", "reviewed_message_ids" => [ m2.id ], "coverage" => "final", "note" => "looked at it" },
      { "reviewer" => "Bob Jones", "reviewed_message_ids" => [], "coverage" => "none", "note" => "not assessed" },
      { "reviewer" => "Dan Hill", "reviewed_message_ids" => [ m1.id ], "coverage" => "earlier", "note" => "looked at it" }
    ])
    expect(row).to have_attributes(reviewers_final: 1, reviewers_earlier: 1, reviewers_none: 1)
    expect(run.error).to eq("reviewer not in trailers: Carol King for #{commit.sha}")
  end

  it "accepts any reviewer name on extras" do
    found = create(:commit)
    ex = extra(found.sha).merge("reviews" => [ review("Someone Else") ])
    ingest(answer.merge("extra_commits" => [ ex ]))
    row = run.verdicts.find_by(commit_id: found.id)
    expect(row.reviews.map { |r| r["reviewer"] }).to eq([ "Someone Else" ])
    expect(row.reviewers_final).to eq(1)
    expect(run.reload.error).to be_nil
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
    data["story"] = "ends in #{commit.sha} after [msg:#{m1.id}]"
    ingest(data)
    run.reload
    expect(run.lineages.find_by(message_id: m2.id).reason).to eq("rebased per [msg:#{m1.id}]")
    expect(run.verdicts.first.evidence).to eq("see [msg:#{m1.id}] and [commit:#{other.sha}], also [commit:#{commit.sha}]")
    expect(run.verdicts.first.reviews.first["note"]).to eq("in [msg:#{m2.id}]")
    expect(run.story).to eq("ends in [commit:#{commit.sha}] after [msg:#{m1.id}]")
    expect(run.raw_result["story"]).to eq(data["story"])
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
end
