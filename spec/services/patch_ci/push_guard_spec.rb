require "rails_helper"

RSpec.describe PatchCi::PushGuard do
  around do |example|
    Dir.mktmpdir { |dir| @repo_dir = File.join(dir, "repo"); example.run }
  end

  let(:fixture) { GitFixtureRepo.new(@repo_dir) }
  let(:repo) { PatchBranches::GitRepo.new(fixture.path) }
  let(:guard) { described_class.new(repo) }

  def ac_init
    "AC_INIT([PostgreSQL], [20devel], [pgsql-bugs@lists.postgresql.org])\n"
  end

  def branch_with_commit(name, files: { "a.c" => "v2\n" })
    base = fixture.commit(subject: "base #{name}", files: { "configure.ac" => ac_init })
    fixture.commit(subject: "patch #{name}", files: files)
    fixture.create_branch(name)
    fixture.checkout("master")
    base
  end

  def record(branch_name, base_sha, **attrs)
    topic = create(:topic)
    message = create(:message, topic: topic)
    create(:patch_branch, topic: topic, message: message, branch_name: branch_name,
                          base_sha: base_sha, status: "applied", **attrs)
  end

  it "returns nil for a pushable branch" do
    base = branch_with_commit("t1_1")
    row = record("t1_1", base)

    expect(guard.check(row)).to be_nil
  end

  it "rejects a row whose branch is missing from the repo" do
    row = record("t404_1", fixture.commit(subject: "base"))

    expect(guard.check(row)).to eq("branch missing from repo")
  end

  it "rejects a row with no base sha" do
    branch_with_commit("t9_1")
    row = record("t9_1", nil)

    expect(guard.check(row)).to eq("base sha missing")
  end

  it "rejects a branch identical to its base" do
    base = fixture.commit(subject: "base", files: { "configure.ac" => ac_init })
    fixture.create_branch("t2_1")
    row = record("t2_1", base)

    expect(guard.check(row)).to eq("branch has no commits beyond base")
  end

  it "rejects a branch touching .github and gives a reason" do
    base = branch_with_commit("t3_1", files: { ".github/workflows/evil.yml" => "x\n" })
    row = record("t3_1", base)

    expect(guard.check(row)).to eq("patchset touches .github/")
  end

  it "rejects a .github path git would quote" do
    base = branch_with_commit("t3_2", files: { ".github/workflows/\u00e9vil.yml" => "x\n" })
    row = record("t3_2", base)

    expect(guard.check(row)).to eq("patchset touches .github/")
  end

  it "rejects a base that is not on upstream history" do
    fixture.commit(subject: "base", files: { "configure.ac" => ac_init })
    fixture.create_branch("t3_3")
    fixture.checkout("t3_3")
    local_base = fixture.commit(subject: "local", files: { ".github/workflows/evil.yml" => "x\n" })
    fixture.commit(subject: "patch", files: { "a.c" => "v2\n" })
    fixture.checkout("master")
    row = record("t3_3", local_base)

    expect(guard.check(row)).to eq("base not on upstream history")
  end

  it "rejects when the diff against base cannot be computed" do
    branch_with_commit("t8_1")
    row = record("t8_1", "1234567890abcdef1234567890abcdef12345678")

    expect(guard.check(row)).to eq("cannot inspect changed paths")
  end

  it "rejects when the base commit's pg major cannot be determined" do
    base = fixture.commit(subject: "no configure", files: { "README" => "hi\n" })
    fixture.commit(subject: "patch", files: { "a.c" => "v2\n" })
    fixture.create_branch("t6_1")
    fixture.checkout("master")
    row = record("t6_1", base)

    expect(guard.check(row)).to eq("cannot determine pg major of base")
  end

  it "rejects a row that is not applied" do
    base = branch_with_commit("t10_1")
    row = record("t10_1", base)
    row.update_columns(status: "failed")

    expect(guard.check(row)).to eq("row not applied")
  end

  it "rejects a superseded row" do
    base = branch_with_commit("t11_1")
    row = record("t11_1", base)
    row.update!(superseded_by: record("t11_2", base))

    expect(guard.check(row)).to eq("row superseded")
  end

  it "rejects a lineage-only row" do
    base = branch_with_commit("t12_1")
    row = record("t12_1", base, lineage_only: true)

    expect(guard.check(row)).to eq("lineage only row")
  end

  # 8.x predates every era image and no family covers it - a handful of corpus
  # branches really do sit on pre-9.6 bases, so this is the live case
  it "rejects an unsupported era with a reason" do
    base = fixture.commit(subject: "base",
                          files: { "configure.in" => "AC_INIT([PostgreSQL], [8.4devel])\n" })
    fixture.commit(subject: "patch", files: { "a.c" => "v2\n" })
    fixture.create_branch("t7_1")
    fixture.checkout("master")
    row = record("t7_1", base)

    expect(guard.check(row)).to eq("no era image for pg8")
  end
end
