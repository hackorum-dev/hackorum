require "rails_helper"

RSpec.describe PatchCi::Pusher do
  around do |example|
    Dir.mktmpdir do |dir|
      @repo_dir = File.join(dir, "repo")
      @wt_dir = File.join(dir, "wt")
      @remote_dir = File.join(dir, "remote.git")
      example.run
    end
  end

  let(:fixture) { GitFixtureRepo.new(@repo_dir) }
  let(:repo) { PatchBranches::GitRepo.new(fixture.path) }

  def setup_branch(name)
    base = fixture.commit(subject: "base",
                          files: { "configure.ac" => "AC_INIT([PostgreSQL], [20devel])\n" })
    fixture.commit(subject: "patch", files: { "a.c" => "v2\n" })
    fixture.create_branch(name)
    fixture.checkout("master")
    Open3.capture3("git", "init", "--bare", "--quiet", @remote_dir)
    repo.run!("remote", "add", "origin", @remote_dir)
    base
  end

  def pusher
    repo.run!("worktree", "add", "--detach", @wt_dir, "master")
    described_class.new(repo: repo, worktree: PatchBranches::GitRepo.new(@wt_dir))
  end

  def row_for(branch, base, **attrs)
    topic = create(:topic)
    message = create(:message, topic: topic, created_at: Time.utc(2026, 5, 1, 12))
    create(:patch_branch, topic: topic, message: message, branch_name: branch,
                          base_sha: base, status: "applied", on_master: true, **attrs)
  end

  it "passes the topic slug into the stub" do
    base = setup_branch("t9_1")
    row = row_for("t9_1", base)
    row.topic.update!(slug: "my-feature")

    pusher.push(row)

    stub = repo.run!("show", "#{row.reload.pushed_head_sha}:.github/workflows/hackorum-ci.yml").stdout
    expect(stub).to include(%(slug: "my-feature"))
  end

  it "pushes and records the head" do
    base = setup_branch("t9_1")
    row = row_for("t9_1", base)

    expect(pusher.push(row)).to be(true)

    row.reload
    expect(row.ci_status).to eq("pushed_awaiting_ci")
    expect(row.pushed_head_sha).to eq(repo.rev_parse("t9_1"))
    expect(row.pushed_at).to be_present
    remote = PatchBranches::GitRepo.new(@remote_dir)
    expect(remote.rev_parse("t9_1")).to eq(row.pushed_head_sha)
  end

  it "is stable across a second push" do
    base = setup_branch("t10_1")
    row = row_for("t10_1", base)

    pusher.push(row)
    first = row.reload.pushed_head_sha
    FileUtils.rm_rf(@wt_dir)
    repo.run("worktree", "prune")
    pusher.push(row)

    expect(row.reload.pushed_head_sha).to eq(first)
  end

  it "records a rejection instead of pushing" do
    base = setup_branch("t11_1")
    row = row_for("t11_1", base)

    pusher.skip(row, "no era image for pg16")

    row.reload
    expect(row.ci_status).to eq("ci_none")
    expect(row.ci_skip_reason).to eq("no era image for pg16")
    expect(row.pushed_at).to be_nil
  end

  it "skip overwrites to a new reason" do
    base = setup_branch("t15_1")
    row = row_for("t15_1", base, ci_status: "ci_none", ci_skip_reason: "no era image for pg13")
    pshr = pusher

    pshr.skip(row, "branch missing from repo")
    expect(row.reload.ci_skip_reason).to eq("branch missing from repo")
  end

  it "leaves the row unpushed when the remote rejects" do
    base = setup_branch("t12_1")
    repo.run!("remote", "set-url", "origin", "/nonexistent/remote.git")
    row = row_for("t12_1", base)

    expect(pusher.push(row)).to be(false)

    row.reload
    expect(row.pushed_at).to be_nil
    expect(row.ci_skip_reason).to include("push failed")
  end

  it "marks push_failed when the commit builder raises instead of the remote rejecting" do
    base = setup_branch("t14_1")
    topic = create(:topic)
    message = create(:message, topic: topic, created_at: Time.utc(2026, 5, 1, 12))
    message.created_at = nil # in-memory only; created_at is NOT NULL in the db
    row = create(:patch_branch, topic: topic, message: message, branch_name: "t14_1",
                                base_sha: base, status: "applied", on_master: true)

    expect(pusher.push(row)).to be(false)

    row.reload
    expect(row.ci_status).to eq("push_failed")
    expect(row.ci_skip_reason).to be_present
    expect(row.pushed_at).to be_nil
  end

  it "marks push_failed without losing the earlier sha on a failed refresh" do
    base = setup_branch("t13_1")
    row = row_for("t13_1", base)

    p = pusher
    p.push(row)
    first_sha = row.reload.pushed_head_sha

    repo.run!("remote", "set-url", "origin", "/nonexistent/remote.git")
    expect(p.push(row)).to be(false)

    row.reload
    expect(row.ci_status).to eq("push_failed")
    expect(row.pushed_head_sha).to eq(first_sha)
  end
end
