require "rails_helper"

RSpec.describe PatchCi::CiCommitBuilder do
  around do |example|
    Dir.mktmpdir do |dir|
      @repo_dir = File.join(dir, "repo")
      @wt_dir = File.join(dir, "wt")
      example.run
    end
  end

  let(:fixture) { GitFixtureRepo.new(@repo_dir) }
  let(:repo) { PatchBranches::GitRepo.new(fixture.path) }

  def worktree
    repo.run!("worktree", "add", "--detach", @wt_dir, "master")
    PatchBranches::GitRepo.new(@wt_dir)
  end

  def build(wt, base:, **overrides)
    described_class.new(wt).build(
      **{ branch: "t42_3", base_sha: base, on_master: true, pg_major: 20,
          topic_id: 42, message_index: 3, committed_at: Time.utc(2026, 5, 1, 12, 0, 0) }
        .merge(overrides)
    )
  end

  it "keeps the no-slug commit byte-identical" do
    base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
    fixture.create_branch("t42_3")

    expect(build(worktree, base: base)).to eq("7b340b0647c420e08afcbf9c7c155fbcbf844b57")
  end

  it "passes the slug when given" do
    base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
    fixture.create_branch("t42_3")

    sha = build(worktree, base: base, slug: "my-feature")

    stub = repo.run!("show", "#{sha}:.github/workflows/hackorum-ci.yml").stdout
    expect(stub).to include(%(      slug: "my-feature"\n))
  end

  it "omits the slug line without one" do
    base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
    fixture.create_branch("t42_3")

    sha = build(worktree, base: base, slug: nil)

    stub = repo.run!("show", "#{sha}:.github/workflows/hackorum-ci.yml").stdout
    expect(stub).not_to include("slug:")
  end

  it "adds the stub workflow on top of the branch" do
    base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
    fixture.create_branch("t42_3")
    wt = worktree

    sha = build(wt, base: base)

    stub = repo.run!("show", "#{sha}:.github/workflows/hackorum-ci.yml").stdout
    expect(stub).to include("hackorum-dev/postgres-ci/.github/workflows/patch-ci.yml@main")
    expect(stub).to include("pg_major: 20")
    expect(stub).to include("topic_id: 42")
    expect(stub).to include("message_index: 3")
    expect(stub).to include("base_sha: #{base}")
  end

  it "carries the trailers" do
    base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
    fixture.create_branch("t42_3")

    sha = build(worktree, base: base)

    message = repo.run!("log", "-1", "--format=%B", sha).stdout
    expect(message).to include("Hackorum-Base: #{base}")
    expect(message).to include("Hackorum-On-Master: yes")
    expect(message).to include("Hackorum-Message: 3")
    expect(message).to include("Hackorum-CI: full")
  end

  it "deletes upstream pg-ci.yml when present" do
    base = fixture.commit(subject: "base",
                          files: { ".github/workflows/pg-ci.yml" => "name: CI for PostgreSQL\n" })
    fixture.create_branch("t42_3")

    sha = build(worktree, base: base)

    expect(repo.run("show", "#{sha}:.github/workflows/pg-ci.yml")).not_to be_success
  end

  it "produces the same sha on a second run" do
    base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
    fixture.create_branch("t42_3")

    first = build(worktree, base: base)
    FileUtils.rm_rf(@wt_dir)
    repo.run("worktree", "prune")
    second = build(worktree, base: base)

    expect(second).to eq(first)
  end

  it "stamps author and committer dates from the submission time" do
    base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
    fixture.create_branch("t42_3")

    sha = build(worktree, base: base)

    dates = repo.run!("log", "-1", "--format=%cI %aI", sha).stdout.split
    expect(dates).to eq([ "2026-05-01T12:00:00Z", "2026-05-01T12:00:00Z" ])
  end

  it "replaces an existing CI commit instead of stacking a second one" do
    base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
    fixture.create_branch("t42_3")

    build(worktree, base: base)
    FileUtils.rm_rf(@wt_dir)
    repo.run("worktree", "prune")
    sha = build(worktree, base: base, pg_major: 15)

    expect(repo.run!("show", "#{sha}:.github/workflows/hackorum-ci.yml").stdout).to include("pg_major: 15")
    expect(repo.run!("rev-list", "--count", "#{base}..#{sha}").stdout.strip).to eq("1")
  end

  it "does not mistake a patch commit quoting our trailer for its own" do
    base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
    fixture.commit(subject: "sneaky patch",
                   body: "Hackorum-Base: deadbeef\nnot really ours\n",
                   files: { "a.c" => "v2\n" })
    fixture.create_branch("t42_3")
    patch_head = repo.rev_parse("t42_3")

    sha = build(worktree, base: base)

    expect(repo.run!("show", "#{sha}:a.c").stdout).to eq("v2\n")
    expect(repo.run!("rev-parse", "#{sha}^").stdout.strip).to eq(patch_head)
  end

  it "raises when committed_at is missing" do
    base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
    fixture.create_branch("t42_3")

    expect { build(worktree, base: base, committed_at: nil) }.to raise_error(ArgumentError, /committed_at/)
  end

  it "records on_master: no when the branch is not on master" do
    base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
    fixture.create_branch("t42_3")

    sha = build(worktree, base: base, on_master: false)

    expect(repo.run!("log", "-1", "--format=%B", sha).stdout).to include("Hackorum-On-Master: no")
  end
end
