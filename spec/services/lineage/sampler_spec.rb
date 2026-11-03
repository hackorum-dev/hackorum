require "rails_helper"

RSpec.describe Lineage::Sampler do
  def topic_with(patchsets:, commits:, at: Time.zone.parse("2020-01-01"))
    topic = create(:topic, created_at: at)
    patchsets.times { |i| create(:message, topic: topic, is_patch_submission: true, created_at: at + i.days) }
    commits.times { create(:commit_topic, topic: topic, commit: create(:commit)) }
    topic
  end

  it "samples recent topics with 2+ patchsets and trailer commits" do
    rich = topic_with(patchsets: 3, commits: 2)
    control = topic_with(patchsets: 2, commits: 1)
    topic_with(patchsets: 1, commits: 1)
    topic_with(patchsets: 3, commits: 0)

    picked = described_class.recent(limit: 10, from: Time.zone.parse("2018-01-01"))
    expect(picked.map { |t, _| t.id }).to contain_exactly(rich.id, control.id)
    expect(picked.map { |_, cands| cands.size }).to contain_exactly(2, 1)
    expect(picked.flat_map { |_, cands| cands.map { |c| c[:origin] } }.uniq).to eq([ "trailer" ])
  end

  it "fills about two thirds with rich topics and the rest with controls" do
    3.times { topic_with(patchsets: 3, commits: 2) }
    3.times { topic_with(patchsets: 2, commits: 1) }

    picked = described_class.recent(limit: 3, from: Time.zone.parse("2018-01-01"))
    expect(picked.map { |_, cands| cands.size }).to contain_exactly(2, 2, 1)
  end

  it "samples old commits via overlap" do
    commit = create(:commit, committed_at: Time.zone.parse("2005-06-01"))
    commit.commit_files.create!(path: "src/backend/a.c")
    topic = create(:topic)
    2.times do |i|
      m = create(:message, topic: topic, is_patch_submission: true, created_at: Time.zone.parse("2005-05-01") + i.days)
      create(:patch_submission_file, message: m, path: "src/backend/a.c")
    end

    picked = described_class.old(limit: 5)
    expect(picked.size).to eq(1)
    t, cands = picked.first
    expect(t).to eq(topic)
    expect(cands.first[:commit]).to eq(commit)
    expect(cands.first[:origin]).to eq("overlap")
    expect(cands.first[:overlap][:topic_id]).to eq(topic.id)
  end

  it "takes one commit per year before a second from any year" do
    years = [ 2003, 2006, 2009 ]
    topics = years.flat_map do |year|
      2.times.map do |n|
        path = "src/backend/#{year}_#{n}.c"
        commit = create(:commit, committed_at: Time.zone.local(year, 6, 1 + n))
        commit.commit_files.create!(path: path)
        topic = create(:topic)
        2.times do |i|
          m = create(:message, topic: topic, is_patch_submission: true, created_at: Time.zone.local(year, 5, 1 + i))
          create(:patch_submission_file, message: m, path: path)
        end
        [ year, topic ]
      end
    end

    picked = described_class.old(limit: 3, from: Time.zone.local(2000), to: Time.zone.local(2010))
    picked_years = picked.map { |_, cands| cands.first[:commit].committed_at.year }
    expect(picked_years).to match_array(years)
    expect(picked.map { |t, _| t.id }).to all(be_in(topics.map { |_, t| t.id }))
  end
end
