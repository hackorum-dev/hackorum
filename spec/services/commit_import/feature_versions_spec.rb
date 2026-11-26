require "rails_helper"

RSpec.describe CommitImport::Importer, "feature versions" do
  around do |example|
    Dir.mktmpdir("commit-import") do |dir|
      @tmp = dir
      example.run
    end
  end

  def fixture_repo
    @fixture_repo ||= GitFixtureRepo.new(File.join(@tmp, "source"))
  end

  def importer
    described_class.new(repository: CommitImport::Repository.new(path: fixture_repo.path), fetch: false)
  end

  let(:group) { create(:feature_group) }
  let(:trailer) { "Discussion: https://postgr.es/m/feat@example.com\n" }

  before do
    Classify::Setup.call!
    fixture_repo.commit(subject: "base", date: "2025-05-05T00:00:00+00:00")
    fixture_repo.tag("REL_18_BETA1")
    importer.run!
  end

  def feature_thread(message_id: "feat@example.com")
    topic = create(:topic)
    create(:message, topic: topic, message_id: message_id, created_at: Time.zone.parse("2024-01-01"))
    Classify::BotNote.new(topic).write!(%w[feature moderate])
    create(:feature_group_topic, feature_group: group, topic: topic)
    topic
  end

  def versions
    group.feature_group_versions.order(:major).pluck(:major, :status)
  end

  it "computes versions for imported commits" do
    feature_thread
    fixture_repo.commit(subject: "Add the feature", body: trailer)

    importer.run!

    expect(versions).to eq([ [ 19, "in-development" ] ])
  end

  it "computes versions when a message id resolves later" do
    fixture_repo.commit(subject: "Add the feature", body: "Discussion: https://postgr.es/m/late@example.com\n")
    importer.run!
    feature_thread(message_id: "late@example.com")

    importer.run!

    expect(versions).to eq([ [ 19, "in-development" ] ])
  end

  it "ships in-development versions when the release tag arrives" do
    feature_thread
    fixture_repo.commit(subject: "Add the feature", body: trailer)
    importer.run!

    fixture_repo.tag("REL_19_0")
    importer.run!

    expect(versions).to eq([ [ 19, "shipped" ] ])
  end

  it "moves a version when the stable branch is cut" do
    fixture_repo.commit(subject: "beta", date: "2025-12-15T00:00:00+00:00")
    fixture_repo.tag("REL_19_BETA1")
    importer.run!
    feature_thread
    fixture_repo.commit(subject: "Add the feature", body: trailer)
    importer.run!
    expect(versions).to eq([ [ 20, "in-development" ] ])

    fixture_repo.create_branch("REL_19_STABLE")
    importer.run!

    expect(versions).to eq([ [ 19, "in-development" ] ])
  end

  it "drops versions from fixes once backports are grouped" do
    feature_thread
    fixture_repo.create_branch("REL_18_STABLE")
    fixture_repo.commit(subject: "Fix the feature crash", body: trailer, date: "2026-01-01T00:00:00+00:00")
    fixture_repo.checkout("REL_18_STABLE")
    fixture_repo.commit(subject: "Fix the feature crash", body: trailer, date: "2026-01-02T00:00:00+00:00")

    importer.run!

    expect(versions).to be_empty
  end

  it "keeps importing when a version refresh fails" do
    allow(FeatureGroups::Versions).to receive(:refresh_for_commits!).and_raise("versions broke")
    allow(FeatureGroups::Versions).to receive(:refresh_unreleased!).and_raise("versions broke")
    allow(Rails.error).to receive(:report)
    topic = feature_thread
    fixture_repo.create_branch("REL_18_STABLE")
    original = fixture_repo.commit(subject: "Fix the feature crash", body: trailer, date: "2026-01-01T00:00:00+00:00")
    fixture_repo.tag("REL_19_0")
    fixture_repo.checkout("REL_18_STABLE")
    backport = fixture_repo.commit(subject: "Fix the feature crash", body: trailer, date: "2026-01-02T00:00:00+00:00")

    importer.run!

    expect(Commit.find_by(sha: original)).to have_attributes(released_in: "19.0", topics: [ topic ])
    expect(Commit.find_by(sha: backport).cherry_picked_from_sha).to eq(original)
    expect(Rails.error).to have_received(:report)
      .with(having_attributes(message: "versions broke"), hash_including(handled: true)).exactly(4).times
  end

  it "recomputes versions on reparse" do
    fixture_repo.commit(subject: "Add the feature", body: trailer)
    importer.run!
    feature_thread

    importer.reparse!

    expect(versions).to eq([ [ 19, "in-development" ] ])
  end
end
