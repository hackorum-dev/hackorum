require "rails_helper"

RSpec.describe Classify::Ingestor do
  before { Classify::Setup.call! }

  let(:topic) { create(:topic) }
  let(:run) { create(:classification_run, topic:, status: "claimed", finished_at: nil) }
  let(:no_group) { { id: nil, new_name: nil, new_summary: nil } }

  def ingest(kind: "feature", size: "moderate", enhancement: kind == "feature" ? false : nil, not_a_bug: false, group: no_group, join_linked: [])
    data = { kind:, size:, enhancement:, not_a_bug:, group:, join_linked:, feature_name: "x", evidence: [ "e" ], confidence: "high" }
    file = Tempfile.new([ "result", ".json" ])
    file.write(data.to_json)
    file.close
    described_class.new(run).call(file.path)
  ensure
    file&.unlink
  end

  def note_body = Classify::BotNote.new(topic).note&.body

  it "writes tags and membership" do
    ingest(group: { id: nil, new_name: "SQL/PGQ", new_summary: "graph queries" })
    group = FeatureGroup.sole
    expect(group).to have_attributes(name: "SQL/PGQ", summary: "graph queries", source: "llm", created_by_run_id: run.id)
    expect(note_body).to eq("@global #feature #moderate")
    expect(topic.reload.feature_group_topic).to have_attributes(feature_group_id: group.id, source: "llm", classification_run_id: run.id)
    expect(run.reload).to have_attributes(status: "done", kind: "feature", size: "moderate", not_a_bug: false, feature_group_id: group.id)
    expect(run.finished_at).to be_present
    expect(run.result).to include("kind" => "feature")
  end

  it "tags enhancements" do
    ingest(enhancement: true)
    expect(note_body).to eq("@global #feature #moderate #enhancement")
    expect(run.reload.enhancement).to be(true)
  end

  it "stores enhancement false for sized kinds" do
    ingest(kind: "performance", size: "minor", enhancement: false)
    expect(run.reload.enhancement).to be(false)
  end

  it "accepts enhancement false on a non-sized kind and stores nil" do
    ingest(kind: "bug", size: nil, enhancement: false)
    expect(note_body).to eq("@global #bug")
    expect(run.reload.enhancement).to be_nil
  end

  it "requires enhancement for sized kinds only" do
    expect { ingest(kind: "bug", size: nil, enhancement: true) }.to raise_error(described_class::Error, "enhancement not allowed for bug")
    expect { ingest(enhancement: nil) }.to raise_error(described_class::Error, "enhancement required for feature")
    expect { ingest(kind: "performance", size: "minor", enhancement: nil) }.to raise_error(described_class::Error, "enhancement required for performance")
  end

  it "tags not-a-bug only on bugs" do
    ingest(kind: "bug", size: nil, not_a_bug: true)
    expect(note_body).to eq("@global #bug #not-a-bug")
    other = create(:topic)
    described_class.new(create(:classification_run, topic: other, status: "claimed")).tap do |i|
      file = Tempfile.new([ "r", ".json" ])
      file.write({ kind: "feature", size: "minor", enhancement: false, not_a_bug: true, group: no_group, join_linked: [], feature_name: "x", evidence: [ "e" ], confidence: "low" }.to_json)
      file.close
      i.call(file.path)
    end
    expect(Classify::BotNote.new(other).note.body).to eq("@global #feature #minor")
  end

  it "reuses a group whose name matches after normalization" do
    existing = create(:feature_group, name: "SQL/PGQ")
    ingest(group: { id: nil, new_name: " sql/pgq", new_summary: "x" })
    expect(FeatureGroup.count).to eq(1)
    expect(topic.reload.feature_group_topic.feature_group).to eq(existing)
  end

  it "maps a new_name of a merged group to the survivor" do
    gone = create(:feature_group, name: "SQL/PGQ")
    survivor = create(:feature_group, name: "Graph queries")
    gone.merge_into!(survivor)
    ingest(group: { id: nil, new_name: "sql/pgq", new_summary: "x" })
    expect(FeatureGroup.count).to eq(2)
    expect(topic.reload.feature_group_topic.feature_group).to eq(survivor)
    expect(run.reload.feature_group_id).to eq(survivor.id)
  end

  it "follows merged groups and rejects unknown ids" do
    old = create(:feature_group)
    survivor = create(:feature_group)
    old.merge_into!(survivor)
    ingest(group: { id: old.id, new_name: nil, new_summary: nil })
    expect(topic.reload.feature_group_topic.feature_group).to eq(survivor)

    other = create(:topic)
    other_run = create(:classification_run, topic: other, status: "claimed")
    file = Tempfile.new([ "r", ".json" ])
    file.write({ kind: "feature", size: "minor", enhancement: false, not_a_bug: false, group: { id: 999_999, new_name: nil, new_summary: nil }, join_linked: [], feature_name: "x", evidence: [ "e" ], confidence: "low" }.to_json)
    file.close
    expect { described_class.new(other_run).call(file.path) }.to raise_error(described_class::Error)
    expect(Note.where(topic: other)).to be_empty
    expect(other_run.reload.status).to eq("claimed")
  end

  it "removes a seed or llm membership on a null group" do
    create(:feature_group_topic, topic:, source: "seed")
    ingest
    expect(FeatureGroupTopic.where(topic:)).to be_empty
    expect(run.reload.feature_group_id).to be_nil
  end

  it "leaves locked notes and human memberships alone" do
    human_group = create(:feature_group)
    create(:feature_group_topic, topic:, feature_group: human_group, source: "human")
    Classify::BotNote.new(topic).write!(%w[feature minor])
    admin = create(:user, admin: true)
    NoteBuilder.new(author: admin).update!(note: Classify::BotNote.new(topic).note, body: "@global #feature #major")
    ingest(group: { id: nil, new_name: "Other", new_summary: nil })
    expect(note_body).to eq("@global #feature #major")
    expect(topic.reload.feature_group_topic).to have_attributes(feature_group_id: human_group.id, source: "human")
    expect(run.reload).to have_attributes(status: "done", feature_group_id: nil)
    expect(FeatureGroup.where(name: "Other")).to be_empty
  end

  it "records an id answer under a human membership" do
    create(:feature_group_topic, topic:, feature_group: create(:feature_group), source: "human")
    answer = create(:feature_group)
    ingest(group: { id: answer.id, new_name: nil, new_summary: nil })
    expect(run.reload.feature_group_id).to eq(answer.id)
    expect(topic.reload.feature_group_topic.feature_group_id).not_to eq(answer.id)
  end

  it "keeps a human null membership" do
    create(:feature_group_topic, topic:, feature_group: nil, source: "human")
    ingest(group: { id: nil, new_name: "Other", new_summary: nil })
    expect(topic.reload.feature_group_topic).to have_attributes(feature_group_id: nil, source: "human")
    expect(FeatureGroup.count).to eq(0)
  end

  describe "join_linked" do
    let(:hackers) { create(:mailing_list, identifier: "pgsql-hackers") }
    let(:u) { on_list(create(:topic), hackers) }
    let(:v) { on_list(create(:topic), hackers) }
    let(:w) { on_list(create(:topic), hackers) }
    let(:g) { create(:feature_group) }
    let(:g2) { create(:feature_group) }
    let(:answer) { { id: g.id, new_name: nil, new_summary: nil } }

    def on_list(t, list)
      create(:topic_mailing_list, topic: t, mailing_list: list)
      t
    end

    before do
      create(:topic_link, topic:, other_topic: u, kind: "mention", direction: "out")
      create(:topic_link, topic:, other_topic: v, kind: "mention", direction: "out")
      create(:feature_group_topic, topic: v, feature_group: g2, source: "llm")
    end

    it "skips linked threads outside the classified lists" do
      committers = on_list(create(:topic, title: "pgsql: Add a thing"), create(:mailing_list, identifier: "pgsql-committers"))
      create(:topic_link, topic:, other_topic: committers, kind: "mention", direction: "out")
      ingest(group: answer, join_linked: [ committers.id, u.id ])
      expect(committers.reload.feature_group_topic).to be_nil
      expect(u.reload.feature_group_topic.feature_group_id).to eq(g.id)
    end

    it "adds unassigned linked threads to the group" do
      allow(FeatureGroups::Versions).to receive(:refresh!)
      ingest(group: answer, join_linked: [ u.id, v.id, w.id ])
      expect(u.reload.feature_group_topic).to have_attributes(feature_group_id: g.id, source: "llm", classification_run_id: run.id)
      expect(v.reload.feature_group_topic.feature_group_id).to eq(g2.id)
      expect(w.reload.feature_group_topic).to be_nil
      expect(FeatureGroups::Versions).to have_received(:refresh!).with(include(g.id))
    end

    it "ignores the list when the thread has a human membership" do
      create(:feature_group_topic, topic:, feature_group: g2, source: "human")
      ingest(group: answer, join_linked: [ u.id ])
      expect(u.reload.feature_group_topic).to be_nil
    end

    it "ignores the list when the answer has no group" do
      ingest(join_linked: [ u.id ])
      expect(u.reload.feature_group_topic).to be_nil
    end

    it "counts a null-group row as a row" do
      create(:feature_group_topic, topic: u, feature_group: nil, source: "llm")
      ingest(group: answer, join_linked: [ u.id ])
      expect(u.reload.feature_group_topic).to have_attributes(feature_group_id: nil)
    end

    it "skips merged-away topics" do
      create(:topic_link, topic:, other_topic: w, kind: "mention", direction: "out")
      w.update_column(:merged_into_topic_id, u.id)
      ingest(group: answer, join_linked: [ w.id ])
      expect(w.reload.feature_group_topic).to be_nil
    end

    it "requires the key" do
      file = Tempfile.new([ "r", ".json" ])
      file.write({ kind: "bug", size: nil, enhancement: nil, not_a_bug: false, group: no_group, feature_name: "x", evidence: [ "e" ], confidence: "low" }.to_json)
      file.close
      expect { described_class.new(run).call(file.path) }.to raise_error(described_class::Error, /join_linked/)
    end
  end

  it "rejects a size on a bug" do
    expect { ingest(kind: "bug", size: "minor") }.to raise_error(described_class::Error)
    expect(Note.where(topic:)).to be_empty
  end

  it "rejects a missing size on a feature, and id with new_name" do
    expect { ingest(size: nil) }.to raise_error(described_class::Error)
    g = create(:feature_group)
    expect { ingest(group: { id: g.id, new_name: "n", new_summary: nil }) }.to raise_error(described_class::Error)
  end

  it "rejects schema violations" do
    file = Tempfile.new([ "r", ".json" ])
    file.write({ kind: "nope" }.to_json)
    file.close
    expect { described_class.new(run).call(file.path) }.to raise_error(described_class::Error)
  end

  it "does not fail the run on a version refresh error" do
    allow(FeatureGroups::Versions).to receive(:compute).and_raise(ActiveRecord::StatementInvalid, "boom")
    allow(Rails.error).to receive(:report)
    ingest(group: { id: nil, new_name: "SQL/PGQ", new_summary: "x" })
    expect(run.reload.status).to eq("done")
    expect(topic.reload.feature_group_topic).to be_present
    expect(Rails.error).to have_received(:report).with(an_instance_of(ActiveRecord::StatementInvalid), hash_including(handled: true))
  end

  it "refreshes versions of the old and new group" do
    old = create(:feature_group)
    create(:feature_group_topic, topic:, feature_group: old, source: "llm")
    new_group = create(:feature_group)
    allow(FeatureGroups::Versions).to receive(:refresh!)
    ingest(group: { id: new_group.id, new_name: nil, new_summary: nil })
    expect(FeatureGroups::Versions).to have_received(:refresh!) { |ids| expect(ids).to match_array([ old.id, new_group.id ]) }
  end
end
