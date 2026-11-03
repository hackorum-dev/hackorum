require "rails_helper"

RSpec.describe PatchBranches::CandidateSelector do
  let(:from) { Time.utc(2017, 1, 1) }
  let(:to) { Time.utc(2026, 6, 1) }
  let(:selector) { described_class.new(from: from, to: to) }

  def patch_message(topic, at)
    create(:message, topic: topic, is_patch_submission: true, created_at: at)
  end

  it "returns the latest patch message per topic" do
    topic = create(:topic)
    patch_message(topic, Time.utc(2020, 1, 1))
    latest = patch_message(topic, Time.utc(2021, 1, 1))

    expect(selector.candidates.map(&:id)).to eq([ latest.id ])
  end

  it "excludes topics whose latest patch is outside the range" do
    topic = create(:topic)
    patch_message(topic, Time.utc(2020, 1, 1))
    patch_message(topic, Time.utc(2026, 7, 1))

    expect(selector.candidates).to be_empty
  end

  it "excludes committed topics" do
    topic = create(:topic)
    patch_message(topic, Time.utc(2020, 1, 1))
    create(:commit_topic, topic: topic)

    expect(selector.candidates).to be_empty
  end

  it "keeps a topic that only has an llm link" do
    topic = create(:topic)
    latest = patch_message(topic, Time.utc(2020, 1, 1))
    create(:commit_topic, topic: topic, source: "llm", confidence: 0.9)

    expect(selector.candidates.map(&:id)).to eq([ latest.id ])
  end

  it "excludes merged topics" do
    target = create(:topic)
    topic = create(:topic, merged_into_topic: target)
    patch_message(topic, Time.utc(2020, 1, 1))

    expect(selector.candidates).to be_empty
  end

  it "ignores non-patch messages" do
    topic = create(:topic)
    patch_message(topic, Time.utc(2020, 1, 1))
    create(:message, topic: topic, created_at: Time.utc(2025, 1, 1))

    expect(selector.candidates.map(&:created_at)).to eq([ Time.utc(2020, 1, 1) ])
  end

  it "for_topic returns the latest patch message without filters" do
    topic = create(:topic)
    create(:commit_topic, topic: topic)
    latest = patch_message(topic, Time.utc(2026, 7, 1))

    expect(described_class.for_topic(topic.id).map(&:id)).to eq([ latest.id ])
  end
end
