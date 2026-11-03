require "rails_helper"

RSpec.describe Lineage::CandidateFinder do
  def topic_with_paths(paths, at:, patchsets: 2)
    topic = create(:topic)
    patchsets.times do |i|
      m = create(:message, topic: topic, created_at: at - i.days, is_patch_submission: true)
      paths.each { |p| create(:patch_submission_file, message: m, path: p) }
    end
    topic
  end

  let(:committed_at) { Time.zone.parse("2010-06-01") }
  let(:commit) do
    c = create(:commit, committed_at: committed_at)
    %w[src/backend/a.c src/backend/b.c configure].each { |p| c.commit_files.create!(path: p) }
    c
  end

  it "ranks the exact overlap first and drops far-away, thin and noise-only topics" do
    exact = topic_with_paths(%w[src/backend/a.c src/backend/b.c], at: committed_at - 10.days)
    topic_with_paths(%w[src/backend/a.c src/backend/zzz.c], at: committed_at - 20.days)
    topic_with_paths(%w[src/backend/a.c src/backend/b.c], at: committed_at - 200.days)
    topic_with_paths(%w[src/backend/a.c src/backend/b.c], at: committed_at - 5.days, patchsets: 1)
    topic_with_paths(%w[configure], at: committed_at - 1.day)
    rare = topic_with_paths(%w[src/backend/b.c], at: committed_at - 15.days)
    common = topic_with_paths(%w[src/backend/a.c], at: committed_at - 15.days)

    ranked = described_class.new.overlap_topics(commit)
    expect(ranked.map { |r| r[:topic_id] }).to eq([ exact.id, rare.id, common.id ])
    expect(ranked.first[:matched_paths]).to eq(%w[src/backend/a.c src/backend/b.c])
    expect(ranked.map { |r| r[:score] }).to eq(ranked.map { |r| r[:score] }.sort.reverse)
    expect(ranked[1][:score]).to be > ranked[2][:score]
    expect(ranked.first[:date_gap_days]).to eq(11)
  end

  it "returns nothing for a commit without files" do
    expect(described_class.new.overlap_topics(create(:commit))).to eq([])
  end

  it "lists trailer commits only" do
    topic = create(:topic)
    t = create(:commit)
    create(:commit_topic, topic: topic, commit: t)
    create(:commit_topic, topic: topic, commit: create(:commit), source: "llm", confidence: 0.9)
    expect(described_class.trailer_commits(topic)).to contain_exactly(t)
  end
end
