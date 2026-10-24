require "rails_helper"

RSpec.describe PatchCi::SlugSync do
  around do |example|
    Dir.mktmpdir do |dir|
      @repo_dir = File.join(dir, "repo")
      @remote_dir = File.join(dir, "remote.git")
      example.run
    end
  end

  let(:fixture) { GitFixtureRepo.new(@repo_dir) }
  let(:repo) { PatchBranches::GitRepo.new(fixture.path) }
  let(:now) { Time.utc(2026, 10, 13, 12) }
  let(:clock) { [ now ] }

  before do
    fixture.commit(subject: "base")
    Open3.capture3("git", "init", "--bare", "--quiet", @remote_dir)
    repo.run!("remote", "add", "origin", @remote_dir)
    PatchCiRepoState.create!(master_sha: "a" * 40, master_committed_at: now,
                             master_commit_height: 1, fetched_at: now)
  end

  def sync
    described_class.new(repo: repo, now: -> { clock.first })
  end

  def remote_sha
    out, _err, status = Open3.capture3("git", "-C", @remote_dir, "rev-parse", "refs/heads/hackorum-slugs")
    status.success? ? out.strip : nil
  end

  def remote_file(path)
    Open3.capture3("git", "-C", @remote_dir, "show", "refs/heads/hackorum-slugs:#{path}").first
  end

  it "renders active slugs ordered by slug" do
    b = create(:topic, slug: "bbb")
    a = create(:topic, slug: "aaa")
    target = create(:topic)
    create(:topic, slug: "merged", merged_into_topic: target)

    expect(JSON.parse(sync.slugs_json)).to eq([ { "slug" => "aaa", "topic_id" => a.id },
                                                { "slug" => "bbb", "topic_id" => b.id } ])
  end

  it "pushes the slug list and the stub" do
    topic = create(:topic, slug: "my-feature")

    result = sync.call

    expect(result.pushed).to be(true)
    expect(JSON.parse(remote_file("slugs.json"))).to eq([ { "slug" => "my-feature", "topic_id" => topic.id } ])
    expect(remote_file(".github/workflows/hackorum-slugs.yml"))
      .to include("hackorum-dev/postgres-ci/.github/workflows/slug-tags.yml@main")
    state = PatchCiRepoState.current
    expect(state.slug_sync_digest).to be_present
    expect(state.slug_sync_pushed_at).to eq(now)
  end

  it "pushes a tree with exactly the two files" do
    create(:topic, slug: "my-feature")
    sync.call

    out, = Open3.capture3("git", "-C", @remote_dir, "ls-tree", "-r", "--name-only", "refs/heads/hackorum-slugs")
    expect(out.split("\n")).to contain_exactly(".github/workflows/hackorum-slugs.yml", "slugs.json")
  end

  it "skips an unchanged set within the resync window" do
    create(:topic, slug: "my-feature")
    sync.call
    first = remote_sha
    clock[0] = now + 1.hour

    expect(sync.call.pushed).to be(false)
    expect(remote_sha).to eq(first)
  end

  it "pushes when the set changes" do
    topic = create(:topic, slug: "my-feature")
    sync.call
    topic.update!(slug: "renamed")
    clock[0] = now + 1.hour

    expect(sync.call.pushed).to be(true)
    expect(remote_file("slugs.json")).to include("renamed")
  end

  it "pushes a fresh commit after the resync window" do
    create(:topic, slug: "my-feature")
    sync.call
    first = remote_sha
    clock[0] = now + 24.hours

    expect(sync.call.pushed).to be(true)
    expect(remote_sha).not_to eq(first)
  end

  it "does nothing without slugs on a fresh state" do
    expect(sync.call.pushed).to be(false)
    expect(remote_sha).to be_nil
  end

  it "keeps the state on a failed push" do
    create(:topic, slug: "my-feature")
    repo.run!("remote", "set-url", "origin", File.join(@repo_dir, "missing.git"))

    result = sync.call

    expect(result.pushed).to be(false)
    expect(result.error).to match(/push failed/)
    expect(PatchCiRepoState.current.slug_sync_pushed_at).to be_nil
  end
end
