require "rails_helper"

RSpec.describe Lineage::TriangleBuilder do
  def parsed(path, added)
    Lineage::DiffParser::Result.new(
      files: [ Lineage::DiffParser::FileDiff.new(path: path, area: :code, added: Set.new(added), removed: Set.new) ],
      subjects: [ "s" ])
  end

  def patchset(topic, ordinal, parsed)
    Lineage::PatchsetEnumerator::Patchset.new(
      message: create(:message, topic: topic), ordinal: ordinal, dir: nil, files: [], parsed: parsed, parse_error: nil)
  end

  it "writes one pair per later/earlier combination and replaces old rows" do
    topic = create(:topic)
    sets = [ patchset(topic, 1, parsed("a.c", %w[x])), patchset(topic, 2, parsed("a.c", %w[x y])),
             patchset(topic, 3, nil) ]
    create(:patchset_pair, topic: topic)

    pairs = described_class.new(topic, sets).call
    expect(pairs.size).to eq(3)
    expect(PatchsetPair.where(topic_id: topic.id).count).to eq(3)
    p12 = pairs.find { |p| p[:later_message_id] == sets[1].message.id && p[:earlier_message_id] == sets[0].message.id }
    expect(p12[:metrics]["file_jaccard"]).to eq(1.0)
    p31 = pairs.find { |p| p[:later_message_id] == sets[2].message.id }
    expect(p31[:metrics]).to eq({ "unparsed" => true })
  end

  it "scores commits against every patchset" do
    topic = create(:topic)
    sets = [ patchset(topic, 1, parsed("a.c", %w[x])) ]
    commit = create(:commit)
    entry = Lineage::CommitDiff::Entry.new(commit: commit, sha: commit.sha, available: true, message_text: "m", diff_text: "d", parsed: parsed("a.c", %w[x]))

    scores = described_class.new(topic, sets).commit_scores([ entry ])
    expect(scores.size).to eq(1)
    expect(scores.first[:sha]).to eq(commit.sha)
    expect(scores.first[:metrics]["added_jaccard"]).to eq(1.0)
  end

  it "marks unavailable commits unparsed and keeps the sha" do
    topic = create(:topic)
    sets = [ patchset(topic, 1, parsed("a.c", %w[x])) ]
    entry = Lineage::CommitDiff::Entry.new(commit: nil, sha: "a" * 40, available: false)

    scores = described_class.new(topic, sets).commit_scores([ entry ])
    expect(scores.first[:sha]).to eq("a" * 40)
    expect(scores.first[:metrics]).to eq({ "unparsed" => true })
  end
end
