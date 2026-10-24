require "rails_helper"

RSpec.describe PatchBranches::BaseCommitDetector do
  include PatchSeriesHelper

  around do |example|
    Dir.mktmpdir do |dir|
      @repo_dir = File.join(dir, "repo")
      @patch_dir = File.join(dir, "patches")
      FileUtils.mkdir_p(@patch_dir)
      example.run
    end
  end

  let(:fixture) { GitFixtureRepo.new(@repo_dir) }
  let(:repo) { PatchBranches::GitRepo.new(fixture.path) }

  it "uses the base-commit trailer when present" do
    base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
    patch = File.join(@patch_dir, "0001-x.patch")
    File.write(patch, "From: someone\nSubject: x\n\n---\nbase-commit: #{base}\n")

    detection = described_class.new(repo, [ patch ]).detect
    expect(detection.sha).to eq(base)
    expect(detection.source).to eq("base_line")
  end

  it "ignores base-commit trailers pointing at unknown commits" do
    fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
    patch = File.join(@patch_dir, "0001-x.patch")
    File.write(patch, "base-commit: #{'0' * 40}\n")

    detection = described_class.new(repo, [ patch ]).detect
    expect(detection).to be_nil
  end

  it "ignores base-commit trailers pointing at commits off upstream history" do
    fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
    fixture.create_branch("t1_1")
    fixture.checkout("t1_1")
    local = fixture.commit(subject: "local only", files: { ".github/x.yml" => "x\n" })
    fixture.checkout("master")
    patch = File.join(@patch_dir, "0001-x.patch")
    File.write(patch, "base-commit: #{local}\n")

    detection = described_class.new(repo, [ patch ]).detect
    expect(detection).to be_nil
  end

  it "matches blob hashes against master head" do
    head = fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
    patch = generate_patch(fixture.path, head, "a.c", "v2\n", @patch_dir)

    detection = described_class.new(repo, [ patch ]).detect
    expect(detection.sha).to eq(head)
    expect(detection.source).to eq("master_head")
  end

  it "searches history when master head does not match" do
    old = fixture.commit(subject: "old", files: { "a.c" => "v1\n" })
    fixture.commit(subject: "newer", files: { "a.c" => "v2\n" })
    patch = generate_patch(fixture.path, old, "a.c", "patched\n", @patch_dir)

    detection = described_class.new(repo, [ patch ]).detect
    expect(detection.sha).to eq(old)
    expect(detection.source).to eq("history")
  end

  it "matches a multi-file patch only where all files match" do
    old = fixture.commit(subject: "old", files: { "a.c" => "v1\n", "b.c" => "w1\n" })
    fixture.commit(subject: "newer", files: { "a.c" => "v2\n" })
    a_before = repo.blob_sha(old, "a.c")
    b_before = repo.blob_sha(old, "b.c")

    patch = File.join(@patch_dir, "0001-x.patch")
    File.write(patch, <<~PATCH)
      diff --git a/a.c b/a.c
      index #{a_before}..1111111111111111111111111111111111111111 100644
      --- a/a.c
      +++ b/a.c
      @@ -1 +1 @@
      -v1
      +p1
      diff --git a/b.c b/b.c
      index #{b_before}..2222222222222222222222222222222222222222 100644
      --- a/b.c
      +++ b/b.c
      @@ -1 +1 @@
      -w1
      +p2
    PATCH

    detection = described_class.new(repo, [ patch ]).detect
    expect(detection.sha).to eq(old)
    expect(detection.source).to eq("history")
  end

  it "matches paths containing spaces via history search" do
    old = fixture.commit(subject: "old", files: { "sub dir/my file.c" => "v1\n" })
    fixture.commit(subject: "newer", files: { "sub dir/my file.c" => "v2\n" })
    patch = generate_patch(fixture.path, old, "sub dir/my file.c", "patched\n", @patch_dir)

    detection = described_class.new(repo, [ patch ]).detect
    expect(detection.sha).to eq(old)
    expect(detection.source).to eq("history")
  end

  it "returns nil when nothing matches" do
    fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
    patch = File.join(@patch_dir, "0001-x.patch")
    File.write(patch, <<~PATCH)
      diff --git a/a.c b/a.c
      index deadbeefdeadbeefdeadbeefdeadbeefdeadbeef..1111111111111111111111111111111111111111 100644
      --- a/a.c
      +++ b/a.c
      @@ -1 +1 @@
      -x
      +y
    PATCH

    expect(described_class.new(repo, [ patch ]).detect).to be_nil
  end

  it "falls back to submission_head when constraints match nothing but a date is given" do
    fixture.commit(subject: "base", files: { "a.c" => "v1\n" }, date: "2024-01-01T00:00:00+00:00")
    head = repo.rev_parse("master")
    patch = File.join(@patch_dir, "0001-x.patch")
    File.write(patch, <<~PATCH)
      diff --git a/a.c b/a.c
      index deadbeefdeadbeefdeadbeefdeadbeefdeadbeef..1111111111111111111111111111111111111111 100644
      --- a/a.c
      +++ b/a.c
      @@ -1 +1 @@
      -x
      +y
    PATCH

    detection = described_class.new(repo, [ patch ], submission_date: Time.utc(2024, 6, 1)).detect
    expect(detection.sha).to eq(head)
    expect(detection.source).to eq("submission_head")
  end

  it "ignores a mode-only block and still matches the next block's file" do
    old = fixture.commit(subject: "old", files: { "other.c" => "v1\n" })
    fixture.commit(subject: "newer", files: { "other.c" => "v2\n" })
    before = repo.blob_sha(old, "other.c")

    patch = File.join(@patch_dir, "0001-x.patch")
    File.write(patch, <<~PATCH)
      diff --git a/script.sh b/script.sh
      old mode 100644
      new mode 100755
      diff --git a/other.c b/other.c
      index #{before}..1111111111111111111111111111111111111111 100644
      --- a/other.c
      +++ b/other.c
      @@ -1 +1 @@
      -v1
      +patched
    PATCH

    detection = described_class.new(repo, [ patch ]).detect
    expect(detection.sha).to eq(old)
    expect(detection.source).to eq("history")
  end

  it "keeps the first patch's before-hash for a file touched twice in a series" do
    old = fixture.commit(subject: "old", files: { "a.c" => "v1\n" })
    fixture.commit(subject: "newer", files: { "a.c" => "v2\n" })
    patches = generate_patch_series(fixture.path, old, "a.c", "v1a\n", "v1b\n", @patch_dir)

    detection = described_class.new(repo, patches).detect
    expect(detection.sha).to eq(old)
    expect(detection.source).to eq("history")
  end

  it "excludes series-created files from the constraint set" do
    base = fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
    fixture.commit(subject: "newer", files: { "a.c" => "v2\n" })

    git = PatchBranches::GitRepo.new(fixture.path)
    ident = [ "-c", "user.name=t", "-c", "user.email=t@example.com" ]
    git.run!("checkout", "--quiet", "--detach", base)
    File.write(File.join(fixture.path, "new.c"), "n1\n")
    git.run!("add", "new.c")
    git.run!(*ident, "commit", "-qm", "add new")
    File.write(File.join(fixture.path, "new.c"), "n2\n")
    File.write(File.join(fixture.path, "a.c"), "v1 patched\n")
    git.run!(*ident, "commit", "-aqm", "modify both")
    patches = git.run!("format-patch", "-2", "-o", @patch_dir, "HEAD").stdout.split("\n").map(&:strip).sort
    git.run!("checkout", "--quiet", "--force", "master")

    detection = described_class.new(repo, patches).detect
    expect(detection&.sha).to eq(base)
    expect(detection&.source).to eq("history")
  end

  it "ignores a new-file patch and falls through to nil" do
    fixture.commit(subject: "base", files: { "a.c" => "v1\n" })
    patch = File.join(@patch_dir, "0001-x.patch")
    File.write(patch, <<~PATCH)
      diff --git a/newfile.txt b/newfile.txt
      new file mode 100644
      index 0000000..fedcba9
      --- /dev/null
      +++ b/newfile.txt
      @@ -0,0 +1 @@
      +hello
    PATCH

    expect(described_class.new(repo, [ patch ]).detect).to be_nil
  end

  it "falls back to the commit at submission time for bare diffs" do
    fixture.commit(subject: "one", files: { "a.c" => "v1\n" }, date: "2026-01-01T00:00:00+00:00")
    mid = fixture.commit(subject: "two", files: { "a.c" => "v2\n" }, date: "2026-01-05T00:00:00+00:00")
    fixture.commit(subject: "three", files: { "a.c" => "v3\n" }, date: "2026-01-10T00:00:00+00:00")

    patch = File.join(@patch_dir, "bare.diff")
    File.write(patch, <<~PATCH)
      --- a/a.c
      +++ b/a.c
      @@ -1 +1 @@
      -v2
      +patched
    PATCH

    detection = described_class
      .new(repo, [ patch ], submission_date: Time.utc(2026, 1, 7))
      .detect
    expect(detection.sha).to eq(mid)
    expect(detection.source).to eq("submission_head")
  end

  it "returns nil for bare diffs without a submission date" do
    fixture.commit(subject: "base", files: { "a.c" => "v1\n" })

    patch = File.join(@patch_dir, "bare.diff")
    File.write(patch, <<~PATCH)
      --- a/a.c
      +++ b/a.c
      @@ -1 +1 @@
      -v1
      +patched
    PATCH

    expect(described_class.new(repo, [ patch ]).detect).to be_nil
  end
end
