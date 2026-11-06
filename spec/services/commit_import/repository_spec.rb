require "rails_helper"

RSpec.describe CommitImport::Repository do
  around do |example|
    Dir.mktmpdir("commit-import") do |dir|
      @tmp = dir
      example.run
    end
  end

  def fixture_repo
    @fixture_repo ||= GitFixtureRepo.new(File.join(@tmp, "source"))
  end

  describe "#branches" do
    it "reads local branches from a mirror" do
      fixture_repo.commit(subject: "first")
      fixture_repo.create_branch("REL_18_STABLE")
      fixture_repo.create_branch("unrelated")
      mirror = fixture_repo.mirror_to(File.join(@tmp, "mirror.git"))

      repo = described_class.new(path: mirror)
      expect(repo.branches).to contain_exactly([ "master", "master" ],
                                               [ "REL_18_STABLE", "REL_18_STABLE" ])
    end

    it "reads remote-tracking branches from an ordinary clone" do
      fixture_repo.commit(subject: "first")
      fixture_repo.create_branch("REL_18_STABLE")
      clone = fixture_repo.clone_to(File.join(@tmp, "clone"))

      repo = described_class.new(path: clone)
      expect(repo.branches).to include([ "REL_18_STABLE", "origin/REL_18_STABLE" ])
    end

    it "reads remote-tracking branches of a named upstream remote" do
      fixture_repo.commit(subject: "first")
      fixture_repo.create_branch("REL_18_STABLE")
      fixture_repo.create_branch("t123_1")
      bare = fixture_repo.fetch_into_bare(File.join(@tmp, "consolidated.git"))

      repo = described_class.new(path: bare, upstream_remote: "postgres")
      expect(repo.branches).to contain_exactly([ "master", "postgres/master" ],
                                               [ "REL_18_STABLE", "postgres/REL_18_STABLE" ])
    end

    # the patch branches live in refs/heads of the shared repo. The fallback
    # must not fire while upstream refs exist, or the importer would walk them.
    it "ignores local heads while the upstream remote has refs" do
      fixture_repo.commit(subject: "first")
      bare = fixture_repo.fetch_into_bare(File.join(@tmp, "consolidated.git"))
      Open3.capture3("git", "-C", bare, "update-ref", "refs/heads/REL_99_STABLE",
                     "refs/remotes/postgres/master")

      repo = described_class.new(path: bare, upstream_remote: "postgres")
      expect(repo.branches.map(&:first)).not_to include("REL_99_STABLE")
    end

    it "falls back to local heads when the named remote has no refs" do
      fixture_repo.commit(subject: "first")
      fixture_repo.create_branch("REL_18_STABLE")
      mirror = fixture_repo.mirror_to(File.join(@tmp, "mirror.git"))

      repo = described_class.new(path: mirror, upstream_remote: "postgres")
      expect(repo.branches).to contain_exactly([ "master", "master" ],
                                               [ "REL_18_STABLE", "REL_18_STABLE" ])
    end
  end

  describe "#rev_list" do
    it "lists commits newest first" do
      first = fixture_repo.commit(subject: "first", date: "2026-01-01T00:00:00+00:00")
      second = fixture_repo.commit(subject: "second", date: "2026-01-02T00:00:00+00:00")

      repo = described_class.new(path: fixture_repo.path)
      expect(repo.rev_list("master")).to eq([ second, first ])
    end
  end

  describe "#tags and #rev_list_excluding" do
    it "returns tags with dates and excludes known ancestry" do
      first = fixture_repo.commit(subject: "first", date: "2026-01-01T00:00:00+00:00")
      fixture_repo.tag("REL_18_4")
      second = fixture_repo.commit(subject: "second", date: "2026-02-01T00:00:00+00:00")
      fixture_repo.tag("REL_18_5")

      repo = described_class.new(path: fixture_repo.path)
      tags = repo.tags.index_by { |t| t[:name] }

      expect(tags.keys).to contain_exactly("REL_18_4", "REL_18_5")
      expect(tags["REL_18_4"][:commit_sha]).to eq(first)
      expect(tags["REL_18_4"][:released_at]).to eq(Time.zone.parse("2026-01-01T00:00:00+00:00"))
      expect(repo.rev_list_excluding("REL_18_5", [ "REL_18_4" ])).to eq([ second ])
    end
  end

  describe "#commits" do
    it "yields records with metadata and changed files" do
      sha = fixture_repo.commit(
        subject: "Fix the executor",
        body: "Reviewed-by: Tom Lane <tgl@sss.pgh.pa.us>\n",
        files: { "src/backend/executor/execMain.c" => "one", "src/include/nodes/execnodes.h" => "two" },
        date: "2026-03-04T05:06:07+00:00",
        author_name: "Masahiko Sawada", author_email: "sawada.mshk@gmail.com"
      )

      record = described_class.new(path: fixture_repo.path).commits([ sha ]).first

      expect(record.sha).to eq(sha)
      expect(record.subject).to eq("Fix the executor")
      expect(record.body).to include("Reviewed-by: Tom Lane")
      expect(record.author_name).to eq("Masahiko Sawada")
      expect(record.author_email).to eq("sawada.mshk@gmail.com")
      expect(record.committer_name).to eq("Fixture Committer")
      expect(record.committed_at).to eq(Time.zone.parse("2026-03-04T05:06:07+00:00"))
      expect(record.files).to contain_exactly("src/backend/executor/execMain.c",
                                              "src/include/nodes/execnodes.h")
    end

    it "counts added and removed lines" do
      fixture_repo.commit(subject: "base", files: { "a.c" => "one\ntwo\nthree\n", "b.c" => "keep\ndrop\n" })
      sha = fixture_repo.commit(subject: "change",
                                files: { "a.c" => "one\ntwo\nthree\nfour\nfive\nsix\n", "b.c" => "keep\n" })

      record = described_class.new(path: fixture_repo.path).commits([ sha ]).first

      expect(record.lines_added).to eq(3)
      expect(record.lines_removed).to eq(1)
      expect(record.files).to contain_exactly("a.c", "b.c")
    end

    it "treats binary files as zero lines" do
      sha = fixture_repo.commit(subject: "binary", files: { "logo.png" => "\x89PNG\r\n\x1a\n\x00\x00".b })

      record = described_class.new(path: fixture_repo.path).commits([ sha ]).first

      expect(record.lines_added).to eq(0)
      expect(record.lines_removed).to eq(0)
      expect(record.files).to eq([ "logo.png" ])
    end

    it "lists a renamed file under its new path with no line churn" do
      fixture_repo.commit(subject: "base", files: { "a.c" => "one\ntwo\nthree\n" })
      sha = fixture_repo.rename("a.c", "b.c")

      record = described_class.new(path: fixture_repo.path).commits([ sha ]).first

      expect(record.files).to eq([ "b.c" ])
      expect(record.lines_added).to eq(0)
      expect(record.lines_removed).to eq(0)
    end

    it "resolves rename notation to the new path" do
      repo = described_class.new(path: fixture_repo.path)
      {
        "a.c => b.c" => "b.c",
        "src/{old => new}/f.c" => "src/new/f.c",
        "src/{old => }/f.c" => "src/f.c",
        "src/{ => new}/f.c" => "src/new/f.c",
        "{old => new}/f.c" => "new/f.c",
        "{lib => }/f.c" => "f.c",
        "src/f.c" => "src/f.c"
      }.each do |raw, expected|
        expect(repo.send(:rename_target, raw)).to eq(expected), raw
      end
    end

    it "yields one record per sha for many commits" do
      shas = 3.times.map { |i| fixture_repo.commit(subject: "commit #{i}") }
      records = described_class.new(path: fixture_repo.path).commits(shas).to_a
      expect(records.map(&:sha)).to match_array(shas)
    end

    it "scrubs invalid UTF-8 instead of raising" do
      sha = fixture_repo.commit(subject: "Fix caf\xE9 handling".dup.force_encoding("BINARY"))
      record = described_class.new(path: fixture_repo.path).commits([ sha ]).first
      expect(record.subject).to be_valid_encoding
    end
  end

  describe "#sync!" do
    it "does nothing when fetch is disabled" do
      fixture_repo.commit(subject: "first")
      repo = described_class.new(path: fixture_repo.path)
      expect { repo.sync!(fetch: false) }.not_to raise_error
    end

    it "fetches from the origin of an existing clone" do
      fixture_repo.commit(subject: "first")
      clone = fixture_repo.clone_to(File.join(@tmp, "clone"))
      second = fixture_repo.commit(subject: "second")

      repo = described_class.new(path: clone)
      repo.sync!
      expect(repo.rev_list("origin/master")).to include(second)
    end

    it "fetches from a named upstream remote in the consolidated layout" do
      fixture_repo.commit(subject: "first")
      bare = fixture_repo.fetch_into_bare(File.join(@tmp, "consolidated.git"))
      second = fixture_repo.commit(subject: "second")

      repo = described_class.new(path: bare, upstream_remote: "postgres")
      repo.sync!
      expect(repo.rev_list("postgres/master")).to include(second)
    end

    it "raises when the directory is not empty and not a repo" do
      dir = File.join(@tmp, "junk")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "stray.txt"), "x")

      expect { described_class.new(path: dir).sync! }.to raise_error(CommitImport::Error, /not a git repository/)
    end

    it "logs git's stderr output on a successful fetch" do
      fixture_repo.commit(subject: "first")
      clone = fixture_repo.clone_to(File.join(@tmp, "clone"))
      fixture_repo.commit(subject: "second")

      expect(Rails.logger).to receive(:info).with(/commit_import: git fetch:.*master/m)

      described_class.new(path: clone).sync!
    end
  end

  describe "subprocess timeout" do
    # A killed process nobody reaps stays in the table as a zombie, and kill(0)
    # keeps succeeding on it. Whether that happens depends on who plays init:
    # under `task test` rspec itself is pid 1 of the container and never reaps
    # orphans, so dead has to mean "gone or zombie" here.
    def zombie?(pid)
      stat = File.read("/proc/#{pid}/stat")
      stat[stat.rindex(")") + 2] == "Z"
    rescue Errno::ENOENT
      true
    end

    def dead?(pid)
      Process.kill(0, pid)
      zombie?(pid)
    rescue Errno::ESRCH
      true
    end

    # The kill is asynchronous, so give the kernel a moment to tear the process
    # down before calling it a survivor.
    def dead_within?(pid, timeout)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      until dead?(pid)
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.01
      end
      true
    end

    it "kills a hung command after the timeout and reaps it, raising CommitImport::Error" do
      repo = described_class.new(path: @tmp)
      pidfile = File.join(@tmp, "pid")

      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect {
        repo.send(:run, [ "bash", "-c", "echo $$ > #{pidfile}; exec sleep 5" ], timeout: 0.1)
      }.to raise_error(CommitImport::Error, /timed out/)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start

      expect(elapsed).to be < 1

      pid = File.read(pidfile).strip.to_i
      expect(pid).to be > 0
      expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
    end

    it "kills the whole process group, including a backgrounded grandchild that outlives the direct child" do
      repo = described_class.new(path: @tmp)
      pidfile = File.join(@tmp, "grandchild_pid")

      # $BASHPID (not $$, which bash resolves to the top-level shell's pid
      # even inside a subshell) gives the backgrounded sibling's real pid.
      expect {
        repo.send(:run, [ "bash", "-c", "(echo $BASHPID > #{pidfile}; sleep 5) & sleep 5" ], timeout: 0.2)
      }.to raise_error(CommitImport::Error, /timed out/)

      grandchild_pid = File.read(pidfile).strip.to_i
      expect(grandchild_pid).to be > 0
      expect(dead_within?(grandchild_pid, 2)).to be(true),
        "grandchild #{grandchild_pid} survived the group kill"
    end
  end

  describe "#commits with a poison sha" do
    it "skips a sha that does not exist and still yields the valid ones" do
      good1 = fixture_repo.commit(subject: "first")
      good2 = fixture_repo.commit(subject: "second")
      bad = "0" * 40

      repo = described_class.new(path: fixture_repo.path)
      expect(Rails.logger).to receive(:warn).at_least(:once)
      expect(Rails.logger).to receive(:error).with(/skipping poison sha #{bad}/)

      records = repo.commits([ good1, bad, good2 ]).to_a
      expect(records.map(&:sha)).to contain_exactly(good1, good2)
    end

    it "gives up after enough consecutive per-sha failures instead of grinding through the whole batch" do
      fake_shas = (1..15).map { |i| format("%040d", i) }

      repo = described_class.new(path: fixture_repo.path)
      allow(Rails.logger).to receive(:warn)
      allow(Rails.logger).to receive(:error)

      expect { repo.commits(fake_shas).to_a }.to raise_error(CommitImport::Error, /10 consecutive/)
    end
  end

  describe "#commits with corrupted separator bytes in the message" do
    it "skips a chunk with a stray field separator byte but still yields the rest of the batch" do
      good = fixture_repo.commit(subject: "good commit")
      bad = fixture_repo.commit(subject: "subject", body: "body with a stray \x1f byte".dup.force_encoding("BINARY"))

      repo = described_class.new(path: fixture_repo.path)
      expect(Rails.logger).to receive(:error).with(/corrupt git log chunk \(unexpected separator count\)/)

      records = repo.commits([ good, bad ]).to_a
      expect(records.map(&:sha)).to eq([ good ])
    end

    it "skips a chunk with a stray record separator byte but still yields the rest of the batch" do
      good = fixture_repo.commit(subject: "good commit")
      bad = fixture_repo.commit(subject: "subject", body: "body with a stray \x1e byte".dup.force_encoding("BINARY"))

      repo = described_class.new(path: fixture_repo.path)
      expect(Rails.logger).to receive(:error).at_least(:once)

      records = repo.commits([ good, bad ]).to_a
      expect(records.map(&:sha)).to include(good)
      expect(records.map(&:sha)).not_to include(bad)
    end
  end

  describe "#parse_time!" do
    it "raises instead of silently returning nil for an unparsable timestamp" do
      repo = described_class.new(path: @tmp)
      expect { repo.send(:parse_time!, "not-a-real-date", "ctx") }.to raise_error(CommitImport::Error, /ctx/)
    end
  end
end
