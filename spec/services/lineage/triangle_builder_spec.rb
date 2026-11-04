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
end
