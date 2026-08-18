require "rails_helper"

RSpec.describe CommitImport::Importer do
  around do |example|
    Dir.mktmpdir("commit-import") do |dir|
      @tmp = dir
      example.run
    end
  end

  def fixture_repo
    @fixture_repo ||= GitFixtureRepo.new(File.join(@tmp, "source"))
  end

  def importer(**kwargs)
    described_class.new(
      repository: CommitImport::Repository.new(path: fixture_repo.path),
      fetch: false,
      **kwargs
    )
  end

  describe "first import" do
    it "imports commits with metadata, branches and files" do
      sha = fixture_repo.commit(
        subject: "Fix the executor",
        files: { "src/backend/executor/execMain.c" => "a", "src/include/nodes/execnodes.h" => "b" },
        date: "2026-03-04T05:06:07+00:00",
        author_name: "Masahiko Sawada", author_email: "sawada.mshk@gmail.com"
      )

      importer.run!

      commit = Commit.find_by(sha: sha)
      expect(commit.subject).to eq("Fix the executor")
      expect(commit.branches).to eq([ "master" ])
      expect(commit.committed_at).to eq(Time.zone.parse("2026-03-04T05:06:07+00:00"))
      expect(commit.author_email).to eq("sawada.mshk@gmail.com")
      expect(commit.commit_files.pluck(:path)).to contain_exactly(
        "src/backend/executor/execMain.c", "src/include/nodes/execnodes.h"
      )
    end

    it "records branch membership from every branch containing the commit" do
      sha = fixture_repo.commit(subject: "Shared change")
      fixture_repo.create_branch("REL_18_STABLE")

      importer.run!

      expect(Commit.find_by(sha: sha).branches).to contain_exactly("master", "REL_18_STABLE")
    end

    it "stores trailer people and the git committer" do
      body = "Reviewed-by: Tom Lane <tgl@sss.pgh.pa.us>\nAuthor: Dan Dev <dan@example.com>\n"
      sha = fixture_repo.commit(subject: "Credited change", body: body)

      importer.run!

      people = Commit.find_by(sha: sha).commit_people
      expect(people.where(role: "reviewer").pluck(:raw_name)).to eq([ "Tom Lane" ])
      expect(people.where(role: "author").pluck(:raw_name)).to eq([ "Dan Dev" ])
      expect(people.where(role: "committer").pluck(:raw_email)).to eq([ "fixture@example.com" ])
    end

    it "resolves person_id from an alias email" do
      person = create(:person)
      create(:alias, name: "Thomas Lane", email: "tgl@sss.pgh.pa.us", person: person)
      sha = fixture_repo.commit(subject: "x", body: "Reviewed-by: Tom Lane <tgl@sss.pgh.pa.us>\n")

      importer.run!

      row = Commit.find_by(sha: sha).commit_people.find_by(role: "reviewer")
      expect(row.person_id).to eq(person.id)
    end

    it "resolves person_id from an unambiguous name when no email is given" do
      person = create(:person)
      create(:alias, name: "Alexander Lakhin", email: "exclusion@gmail.com", person: person)
      sha = fixture_repo.commit(subject: "x", body: "Reported-by: Alexander Lakhin\n")

      importer.run!

      row = Commit.find_by(sha: sha).commit_people.find_by(role: "reported_by")
      expect(row.person_id).to eq(person.id)
    end

    it "leaves person_id NULL for an ambiguous name" do
      create(:alias, name: "Same Name", email: "one@example.com", person: create(:person))
      create(:alias, name: "Same Name", email: "two@example.com", person: create(:person))
      sha = fixture_repo.commit(subject: "x", body: "Reported-by: Same Name\n")

      importer.run!

      row = Commit.find_by(sha: sha).commit_people.find_by(role: "reported_by")
      expect(row.person_id).to be_nil
    end

    it "links a commit to the topic of its Discussion message" do
      topic = create(:topic)
      create(:message, topic: topic, message_id: "abc-123@example.com")
      sha = fixture_repo.commit(subject: "x", body: "Discussion: https://postgr.es/m/abc-123@example.com\n")

      importer.run!

      commit = Commit.find_by(sha: sha)
      expect(commit.topics).to eq([ topic ])
      expect(commit.commit_topics.first.external_message_id).to eq("abc-123@example.com")
      expect(topic.reload.commit_count).to eq(1)
    end

    it "resolves a percent-encoded message id" do
      topic = create(:topic)
      create(:message, topic: topic, message_id: "CAD21AoA=abc@mail.gmail.com")
      sha = fixture_repo.commit(subject: "x", body: "Discussion: https://postgr.es/m/CAD21AoA%3Dabc%40mail.gmail.com\n")

      importer.run!

      expect(Commit.find_by(sha: sha).topics).to eq([ topic ])
    end

    it "keeps a literal + in a message id" do
      topic = create(:topic)
      create(:message, topic: topic, message_id: "CAN4CZFNka+2q3=-Dit+hr@mail.gmail.com")
      sha = fixture_repo.commit(
        subject: "x",
        body: "Discussion: https://postgr.es/m/CAN4CZFNka+2q3=-Dit+hr@mail.gmail.com\n"
      )

      importer.run!

      expect(Commit.find_by(sha: sha).topics).to eq([ topic ])
    end

    it "resolves a message id listed in the overrides" do
      stub_const("CommitImport::MessageIdOverrides::MAP", { "typo@x" => "real@x" })
      topic = create(:topic)
      create(:message, topic: topic, message_id: "real@x")
      sha = fixture_repo.commit(subject: "x", body: "Discussion: https://postgr.es/m/typo@x\n")

      importer.run!

      commit = Commit.find_by(sha: sha)
      expect(commit.topics).to eq([ topic ])
      expect(commit.unresolved_message_ids).to be_empty
    end

    it "records an unresolved message id" do
      sha = fixture_repo.commit(subject: "x", body: "Discussion: https://postgr.es/m/missing@example.com\n")

      importer.run!

      commit = Commit.find_by(sha: sha)
      expect(commit.topics).to be_empty
      expect(commit.unresolved_message_ids).to eq([ "missing@example.com" ])
    end

    it "honours the limit" do
      3.times { |i| fixture_repo.commit(subject: "commit #{i}") }

      importer(limit: 2).run!

      expect(Commit.count).to eq(2)
    end

    it "records the newest linked commit date on the topic" do
      topic = create(:topic)
      create(:message, topic: topic, message_id: "abc-123@example.com")
      body = "Discussion: https://postgr.es/m/abc-123@example.com\n"
      fixture_repo.commit(subject: "first", body: body, date: "2026-03-01T10:00:00+00:00")
      fixture_repo.commit(subject: "second", body: body, date: "2026-03-05T10:00:00+00:00")

      importer.run!

      expect(topic.reload.last_commit_at).to eq(Time.zone.parse("2026-03-05T10:00:00+00:00"))
    end

    it "leaves last_commit_at null for a topic no commit mentions" do
      topic = create(:topic)
      create(:message, topic: topic, message_id: "abc-123@example.com")
      fixture_repo.commit(subject: "x", body: "")

      importer.run!

      expect(topic.reload.last_commit_at).to be_nil
    end
  end

  describe "incremental runs" do
    it "does not re-import known commits" do
      fixture_repo.commit(subject: "first")
      importer.run!
      expect { importer.run! }.not_to change(Commit, :count)
    end

    it "imports commits added after the first run" do
      fixture_repo.commit(subject: "first")
      importer.run!
      second = fixture_repo.commit(subject: "second")

      importer.run!

      expect(Commit.find_by(sha: second)).to be_present
    end

    it "updates branch sets when a stable branch is cut" do
      sha = fixture_repo.commit(subject: "first")
      importer.run!
      expect(Commit.find_by(sha: sha).branches).to eq([ "master" ])

      fixture_repo.create_branch("REL_19_STABLE")
      importer.run!

      expect(Commit.find_by(sha: sha).branches).to contain_exactly("master", "REL_19_STABLE")
    end

    it "links a message that arrives after the commit" do
      sha = fixture_repo.commit(subject: "x", body: "Discussion: https://postgr.es/m/late@example.com\n")
      importer.run!
      expect(Commit.find_by(sha: sha).unresolved_message_ids).to eq([ "late@example.com" ])

      topic = create(:topic)
      create(:message, topic: topic, message_id: "late@example.com")
      importer.run!

      commit = Commit.find_by(sha: sha)
      expect(commit.topics).to eq([ topic ])
      expect(commit.unresolved_message_ids).to be_empty
      expect(topic.reload.commit_count).to eq(1)
    end

    it "sets last_commit_at when a message id resolves on a later run" do
      fixture_repo.commit(subject: "x", body: "Discussion: https://postgr.es/m/late@example.com\n",
                          date: "2026-03-07T10:00:00+00:00")
      importer.run!

      topic = create(:topic)
      create(:message, topic: topic, message_id: "late@example.com")
      importer.run!

      expect(topic.reload.last_commit_at).to eq(Time.zone.parse("2026-03-07T10:00:00+00:00"))
    end

    it "resolves people for recent commits on a later run" do
      sha = fixture_repo.commit(
        subject: "x", body: "Reviewed-by: Tom Lane <tgl@sss.pgh.pa.us>\n",
        date: 1.day.ago.iso8601
      )
      importer.run!
      expect(Commit.find_by(sha: sha).commit_people.find_by(role: "reviewer").person_id).to be_nil

      person = create(:person)
      create(:alias, name: "Tom Lane", email: "tgl@sss.pgh.pa.us", person: person)
      importer.run!

      expect(Commit.find_by(sha: sha).commit_people.find_by(role: "reviewer").person_id).to eq(person.id)
    end

    it "does not re-resolve people for old commits during a normal run" do
      sha = fixture_repo.commit(
        subject: "x", body: "Reviewed-by: Tom Lane <tgl@sss.pgh.pa.us>\n",
        date: 2.years.ago.iso8601
      )
      importer.run!
      person = create(:person)
      create(:alias, name: "Tom Lane", email: "tgl@sss.pgh.pa.us", person: person)

      importer.run!

      expect(Commit.find_by(sha: sha).commit_people.find_by(role: "reviewer").person_id).to be_nil
    end

    it "resolves old people when asked explicitly" do
      sha = fixture_repo.commit(
        subject: "x", body: "Reviewed-by: Tom Lane <tgl@sss.pgh.pa.us>\n",
        date: 2.years.ago.iso8601
      )
      importer.run!
      person = create(:person)
      create(:alias, name: "Tom Lane", email: "tgl@sss.pgh.pa.us", person: person)

      importer.relink_people!

      expect(Commit.find_by(sha: sha).commit_people.find_by(role: "reviewer").person_id).to eq(person.id)
    end
  end

  describe "error handling" do
    it "aborts without writing partial rows when the repo path is unusable" do
      dir = File.join(@tmp, "junk")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "stray.txt"), "x")
      broken = described_class.new(
        repository: CommitImport::Repository.new(path: dir), fetch: false
      )

      expect { broken.run! }.to raise_error(CommitImport::Error)
      expect(Commit.count).to eq(0)
    end

    it "keeps a topic's commit count correct if a later pass in run! raises" do
      topic = create(:topic)
      create(:message, topic: topic, message_id: "abc-123@example.com")
      fixture_repo.commit(subject: "x", body: "Discussion: https://postgr.es/m/abc-123@example.com\n")

      imp = importer
      allow(imp).to receive(:import_release_tags).and_raise("boom")

      expect { imp.run! }.to raise_error("boom")

      expect(topic.reload.commit_count).to eq(1)
    end
  end

  describe "#reparse!" do
    it "re-derives people and links from stored bodies" do
      topic = create(:topic)
      create(:message, topic: topic, message_id: "abc-123@example.com")
      body = "Reviewed-by: Tom Lane <tgl@sss.pgh.pa.us>\nDiscussion: https://postgr.es/m/abc-123@example.com\n"
      sha = fixture_repo.commit(subject: "x", body: body)
      importer.run!

      Commit.find_by(sha: sha).commit_people.delete_all
      CommitTopic.delete_all

      importer.reparse!

      commit = Commit.find_by(sha: sha)
      expect(commit.commit_people.where(role: "reviewer").count).to eq(1)
      expect(commit.topics).to eq([ topic ])
    end

    it "drops last_commit_at back to null when the trailer is gone" do
      topic = create(:topic)
      create(:message, topic: topic, message_id: "abc-123@example.com")
      fixture_repo.commit(subject: "x",
                          body: "Discussion: https://postgr.es/m/abc-123@example.com\n")
      importer.run!
      expect(topic.reload.last_commit_at).to be_present

      Commit.update_all(body: "")
      importer.reparse!

      expect(topic.reload.last_commit_at).to be_nil
    end
  end
end
