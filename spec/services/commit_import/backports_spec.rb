require "rails_helper"

RSpec.describe CommitImport::Importer, "backports" do
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

  it "keeps an explicit cherry-pick reference" do
    original = fixture_repo.commit(subject: "Fix the vacuum leader race", date: "2026-01-01T00:00:00+00:00")
    backport = fixture_repo.commit(
      subject: "Fix the vacuum leader race",
      body: "(cherry picked from commit #{original})",
      date: "2026-01-02T00:00:00+00:00"
    )

    importer.run!

    expect(Commit.find_by(sha: backport).cherry_picked_from_sha).to eq(original)
  end

  it "groups a backport by subject and author when no reference exists" do
    original = fixture_repo.commit(
      subject: "Fix the vacuum leader race", date: "2026-01-01T00:00:00+00:00",
      author_name: "Masahiko Sawada", author_email: "sawada.mshk@gmail.com"
    )
    fixture_repo.create_branch("REL_18_STABLE")
    fixture_repo.checkout("REL_18_STABLE")
    backport = fixture_repo.commit(
      subject: "Fix the vacuum leader race", date: "2026-01-02T00:00:00+00:00",
      author_name: "Masahiko Sawada", author_email: "sawada.mshk@gmail.com"
    )

    importer.run!

    expect(Commit.find_by(sha: backport).cherry_picked_from_sha).to eq(original)
    expect(Commit.find_by(sha: original).cherry_picked_from_sha).to be_nil
  end

  it "does not group short subjects" do
    fixture_repo.commit(subject: "Typo", date: "2026-01-01T00:00:00+00:00")
    second = fixture_repo.commit(subject: "Typo", date: "2026-01-02T00:00:00+00:00")

    importer.run!

    expect(Commit.find_by(sha: second).cherry_picked_from_sha).to be_nil
  end

  it "does not group commits from different authors" do
    fixture_repo.commit(subject: "Fix the vacuum leader race", date: "2026-01-01T00:00:00+00:00",
                        author_email: "one@example.com")
    second = fixture_repo.commit(subject: "Fix the vacuum leader race", date: "2026-01-02T00:00:00+00:00",
                                 author_email: "two@example.com")

    importer.run!

    expect(Commit.find_by(sha: second).cherry_picked_from_sha).to be_nil
  end

  it "points a three-way backport chain (master + two stable branches) at the same master commit" do
    master = fixture_repo.commit(
      subject: "Fix the vacuum leader race", date: "2026-01-01T00:00:00+00:00",
      author_name: "Masahiko Sawada", author_email: "sawada.mshk@gmail.com"
    )
    fixture_repo.create_branch("REL_18_STABLE")
    fixture_repo.create_branch("REL_17_STABLE")

    fixture_repo.checkout("REL_18_STABLE")
    backport_18 = fixture_repo.commit(
      subject: "Fix the vacuum leader race", date: "2026-01-02T00:00:00+00:00",
      author_name: "Masahiko Sawada", author_email: "sawada.mshk@gmail.com"
    )

    fixture_repo.checkout("REL_17_STABLE")
    backport_17 = fixture_repo.commit(
      subject: "Fix the vacuum leader race", date: "2026-01-03T00:00:00+00:00",
      author_name: "Masahiko Sawada", author_email: "sawada.mshk@gmail.com"
    )

    importer.run!

    expect(Commit.find_by(sha: backport_18).cherry_picked_from_sha).to eq(master)
    expect(Commit.find_by(sha: backport_17).cherry_picked_from_sha).to eq(master)
    expect(Commit.find_by(sha: master).cherry_picked_from_sha).to be_nil
  end

  it "keeps a change reverted and landed again on master canonical" do
    first = fixture_repo.commit(subject: "Implement ALTER TABLE ... MERGE PARTITIONS", date: "2024-04-06T00:00:00+00:00",
                                author_email: "d.koval@example.com")
    again = fixture_repo.commit(subject: "Implement ALTER TABLE ... MERGE PARTITIONS", date: "2025-12-14T00:00:00+00:00",
                                author_email: "d.koval@example.com")

    importer.run!

    expect(Commit.find_by(sha: first).cherry_picked_from_sha).to be_nil
    expect(Commit.find_by(sha: again).cherry_picked_from_sha).to be_nil
  end

  it "attaches a backport to the nearest master commit, not the earliest" do
    fixture_repo.commit(subject: "Translation updates", date: "2024-05-06T00:00:00+00:00",
                        author_email: "peter@example.com")
    nearest = fixture_repo.commit(subject: "Translation updates", date: "2025-05-05T00:00:00+00:00",
                                  author_email: "peter@example.com")
    fixture_repo.create_branch("REL_18_STABLE")
    fixture_repo.checkout("REL_18_STABLE")
    backport = fixture_repo.commit(subject: "Translation updates", date: "2025-05-05T00:10:00+00:00",
                                   author_email: "peter@example.com")

    importer.run!

    expect(Commit.find_by(sha: backport).cherry_picked_from_sha).to eq(nearest)
  end

  it "never marks a master commit as a backport, even when the stable commit is older" do
    fixture_repo.commit(subject: "Initial import", date: "2025-12-01T00:00:00+00:00")
    fixture_repo.create_branch("REL_18_STABLE")
    fixture_repo.checkout("REL_18_STABLE")
    stable = fixture_repo.commit(subject: "Fix the vacuum leader race", date: "2026-01-01T00:00:00+00:00",
                                 author_email: "sawada.mshk@gmail.com")
    fixture_repo.checkout("master")
    master = fixture_repo.commit(subject: "Fix the vacuum leader race", date: "2026-01-01T00:05:00+00:00",
                                 author_email: "sawada.mshk@gmail.com")

    importer.run!

    expect(Commit.find_by(sha: master).cherry_picked_from_sha).to be_nil
    expect(Commit.find_by(sha: stable).cherry_picked_from_sha).to eq(master)
  end

  it "groups a change that only went to stable branches under its earliest commit" do
    fixture_repo.commit(subject: "Initial import", date: "2025-12-01T00:00:00+00:00")
    fixture_repo.create_branch("REL_18_STABLE")
    fixture_repo.create_branch("REL_17_STABLE")
    fixture_repo.checkout("REL_18_STABLE")
    first = fixture_repo.commit(subject: "Disable the warning in the back branches", date: "2026-01-01T00:00:00+00:00",
                                author_email: "tgl@example.com")
    fixture_repo.checkout("REL_17_STABLE")
    second = fixture_repo.commit(subject: "Disable the warning in the back branches", date: "2026-01-01T00:05:00+00:00",
                                 author_email: "tgl@example.com")

    importer.run!

    expect(Commit.find_by(sha: first).cherry_picked_from_sha).to be_nil
    expect(Commit.find_by(sha: second).cherry_picked_from_sha).to eq(first)
  end

  it "does not change anything on a second run (idempotent)" do
    original = fixture_repo.commit(
      subject: "Fix the vacuum leader race", date: "2026-01-01T00:00:00+00:00",
      author_name: "Masahiko Sawada", author_email: "sawada.mshk@gmail.com"
    )
    fixture_repo.create_branch("REL_18_STABLE")
    fixture_repo.checkout("REL_18_STABLE")
    backport = fixture_repo.commit(
      subject: "Fix the vacuum leader race", date: "2026-01-02T00:00:00+00:00",
      author_name: "Masahiko Sawada", author_email: "sawada.mshk@gmail.com"
    )

    importer.run!
    first_pass = Commit.pluck(:sha, :cherry_picked_from_sha).sort

    importer.run!
    second_pass = Commit.pluck(:sha, :cherry_picked_from_sha).sort

    expect(second_pass).to eq(first_pass)
    expect(Commit.find_by(sha: backport).cherry_picked_from_sha).to eq(original)
  end

  describe "#reparse!" do
    it "restores an explicit cherry-pick reference cleared out of band" do
      original = fixture_repo.commit(subject: "Fix the vacuum leader race", date: "2026-01-01T00:00:00+00:00")
      backport = fixture_repo.commit(
        subject: "Fix the vacuum leader race",
        body: "(cherry picked from commit #{original})",
        date: "2026-01-02T00:00:00+00:00"
      )
      importer.run!
      Commit.where(sha: backport).update_all(cherry_picked_from_sha: nil)

      importer.reparse!

      expect(Commit.find_by(sha: backport).cherry_picked_from_sha).to eq(original)
    end

    it "refills the subject/author fallback for a value cleared out of band" do
      original = fixture_repo.commit(
        subject: "Fix the vacuum leader race", date: "2026-01-01T00:00:00+00:00",
        author_name: "Masahiko Sawada", author_email: "sawada.mshk@gmail.com"
      )
      fixture_repo.create_branch("REL_18_STABLE")
      fixture_repo.checkout("REL_18_STABLE")
      backport = fixture_repo.commit(
        subject: "Fix the vacuum leader race", date: "2026-01-02T00:00:00+00:00",
        author_name: "Masahiko Sawada", author_email: "sawada.mshk@gmail.com"
      )
      importer.run!
      Commit.where(sha: backport).update_all(cherry_picked_from_sha: nil)

      importer.reparse!

      expect(Commit.find_by(sha: backport).cherry_picked_from_sha).to eq(original)
    end

    it "does not touch git" do
      fixture_repo.commit(subject: "Fix the vacuum leader race", date: "2026-01-01T00:00:00+00:00")
      importer.run!

      broken_repo = CommitImport::Repository.new(path: File.join(@tmp, "does-not-exist"))
      broken_importer = described_class.new(repository: broken_repo, fetch: false)

      expect { broken_importer.reparse! }.not_to raise_error
    end
  end
end
