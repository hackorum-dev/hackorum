require "rails_helper"

RSpec.describe ProfileStats do
  let(:person) { create(:person) }
  let!(:person_alias) { create(:alias, person: person, email: "stats@example.com") }

  describe "with no activity" do
    it "returns zeros without querying" do
      stats = described_class.new([])
      queries = captured_queries do
        expect(stats.messages_sent).to eq(0)
        expect(stats.first_message_at).to be_nil
        expect(stats.last_message_at).to be_nil
        expect(stats.years_active).to eq(0)
        expect(stats.threads_joined).to eq(0)
        expect(stats.patches_sent).to eq(0)
        expect(stats.patch_threads).to eq(0)
        expect(stats.landed_patch_threads).to eq(0)
        expect(stats.landed_patch_rate).to eq(0)
        expect(stats.commit_credits_total).to eq(0)
        expect(stats.commit_credits_by_role).to eq(
          "author" => 0, "reviewer" => 0,
          "reported_by" => 0, "co_author" => 0, "committer" => 0
        )
      end

      expect(queries).to be_empty
    end

    it "returns zeros for a person who never posted" do
      stats = described_class.new(person.id)

      expect(stats.messages_sent).to eq(0)
      expect(stats.threads_joined).to eq(0)
    end
  end

  describe "#messages_sent and span" do
    before do
      topic = create(:topic, creator_alias: person_alias)
      create(:message, topic: topic, sender: person_alias,
             created_at: Time.utc(2020, 1, 15), updated_at: Time.utc(2020, 1, 15))
      create(:message, topic: topic, sender: person_alias,
             created_at: Time.utc(2024, 8, 20), updated_at: Time.utc(2024, 8, 20))

      other_person = create(:person)
      other_alias = create(:alias, person: other_person, email: "outsider@example.com")
      other_topic = create(:topic, creator_alias: other_alias)
      create(:message, topic: other_topic, sender: other_alias,
             created_at: Time.utc(2019, 1, 1), updated_at: Time.utc(2019, 1, 1))
      create(:message, topic: other_topic, sender: other_alias,
             created_at: Time.utc(2025, 12, 31), updated_at: Time.utc(2025, 12, 31))
    end

    it "counts messages and reports the span" do
      stats = described_class.new(person.id)

      expect(stats.messages_sent).to eq(2)
      expect(stats.first_message_at).to be_within(1.second).of(Time.utc(2020, 1, 15))
      expect(stats.last_message_at).to be_within(1.second).of(Time.utc(2024, 8, 20))
      # Span is ~4.6 years on purpose: floor gives 4, round gives 5, so this
      # fixture actually distinguishes the two instead of agreeing on 4.
      expect(stats.years_active).to eq(4)
    end

    it "memoizes the aggregate in a single query" do
      stats = described_class.new(person.id)

      queries = captured_queries do
        stats.messages_sent
        stats.first_message_at
        stats.last_message_at
      end

      expect(queries.size).to eq(1)
    end
  end

  describe "#threads_joined" do
    it "counts distinct topics across a set of people" do
      other_person = create(:person)
      other_alias = create(:alias, person: other_person, email: "other@example.com")

      shared = create(:topic, creator_alias: person_alias)
      create(:message, topic: shared, sender: person_alias)
      create(:message, topic: shared, sender: other_alias)

      solo = create(:topic, creator_alias: other_alias)
      create(:message, topic: solo, sender: other_alias)

      outsider_person = create(:person)
      outsider_alias = create(:alias, person: outsider_person, email: "unrelated@example.com")
      unrelated = create(:topic, creator_alias: outsider_alias)
      create(:message, topic: unrelated, sender: outsider_alias)

      stats = described_class.new([ person.id, other_person.id ])

      expect(stats.threads_joined).to eq(2)
    end

    it "accepts a Set of ids" do
      topic = create(:topic, creator_alias: person_alias)
      create(:message, topic: topic, sender: person_alias)

      expect(described_class.new(Set[person.id]).threads_joined).to eq(1)
    end

    it "memoizes the count" do
      topic = create(:topic, creator_alias: person_alias)
      create(:message, topic: topic, sender: person_alias)

      stats = described_class.new(person.id)
      stats.threads_joined

      queries = captured_queries { stats.threads_joined }

      expect(queries).to be_empty
    end
  end

  describe "patches" do
    it "counts patch messages and their distinct threads" do
      topic_a = create(:topic, creator_alias: person_alias)
      topic_b = create(:topic, creator_alias: person_alias)
      create(:message, topic: topic_a, sender: person_alias, is_patch_submission: true)
      create(:message, topic: topic_a, sender: person_alias, is_patch_submission: true)
      create(:message, topic: topic_b, sender: person_alias, is_patch_submission: true)
      create(:message, topic: topic_b, sender: person_alias, is_patch_submission: false)

      other_person = create(:person)
      other_alias = create(:alias, person: other_person, email: "other-patcher@example.com")
      other_topic = create(:topic, creator_alias: other_alias)
      create(:message, topic: other_topic, sender: other_alias, is_patch_submission: true)

      stats = described_class.new(person.id)

      expect(stats.patches_sent).to eq(3)
      expect(stats.patch_threads).to eq(2)
    end

    it "returns zero and skips the join when there are no patches" do
      stats = described_class.new(person.id)

      queries = captured_queries do
        expect(stats.landed_patch_threads).to eq(0)
        expect(stats.landed_patch_rate).to eq(0)
      end

      expect(queries.grep(/commit_topics/)).to be_empty
    end

    it "counts a landed thread when a linked commit credits the person as author" do
      topic = create(:topic, creator_alias: person_alias)
      create(:message, topic: topic, sender: person_alias, is_patch_submission: true)

      commit = create(:commit)
      create(:commit_topic, commit: commit, topic: topic)
      CommitPerson.create!(commit: commit, role: "author", person_id: person.id)

      stats = described_class.new(person.id)

      expect(stats.landed_patch_threads).to eq(1)
      expect(stats.landed_patch_rate).to eq(100)
    end

    it "ignores llm-sourced author rows" do
      topic = create(:topic, creator_alias: person_alias)
      create(:message, topic: topic, sender: person_alias, is_patch_submission: true)

      commit = create(:commit)
      create(:commit_topic, commit: commit, topic: topic)
      CommitPerson.create!(commit: commit, role: "author", person_id: person.id, source: "llm", confidence: 0.9)

      expect(described_class.new(person.id).landed_patch_threads).to eq(0)
    end

    it "counts llm-sourced author rows when widened to llm" do
      topic = create(:topic, creator_alias: person_alias)
      create(:message, topic: topic, sender: person_alias, is_patch_submission: true)

      commit = create(:commit)
      create(:commit_topic, commit: commit, topic: topic)
      CommitPerson.create!(commit: commit, role: "author", person_id: person.id, source: "llm", confidence: 0.9)

      expect(described_class.new(person.id, sources: %w[parsed llm]).landed_patch_threads).to eq(1)
    end

    it "counts a thread landed once even when a backport gives it two credited commits" do
      topic = create(:topic, creator_alias: person_alias)
      create(:message, topic: topic, sender: person_alias, is_patch_submission: true)

      main_commit = create(:commit)
      backport_commit = create(:commit)
      create(:commit_topic, commit: main_commit, topic: topic)
      create(:commit_topic, commit: backport_commit, topic: topic)
      CommitPerson.create!(commit: main_commit, role: "author", person_id: person.id)
      CommitPerson.create!(commit: backport_commit, role: "author", person_id: person.id)

      stats = described_class.new(person.id)

      expect(stats.landed_patch_threads).to eq(1)
      expect(stats.landed_patch_rate).to eq(100)
    end

    it "counts a commit credited only as committer as a landed thread" do
      topic = create(:topic, creator_alias: person_alias)
      create(:message, topic: topic, sender: person_alias, is_patch_submission: true)

      commit = create(:commit)
      create(:commit_topic, commit: commit, topic: topic)
      CommitPerson.create!(commit: commit, role: "committer", person_id: person.id)

      stats = described_class.new(person.id)

      expect(stats.landed_patch_threads).to eq(1)
      expect(stats.landed_patch_rate).to eq(100)
    end

    it "excludes patch threads and their landings from before the commit-link era" do
      old_topic = create(:topic, creator_alias: person_alias, created_at: Date.new(2016, 6, 1))
      create(:message, topic: old_topic, sender: person_alias, is_patch_submission: true,
             created_at: Date.new(2016, 6, 1), updated_at: Date.new(2016, 6, 1))
      old_commit = create(:commit)
      create(:commit_topic, commit: old_commit, topic: old_topic)
      CommitPerson.create!(commit: old_commit, role: "author", person_id: person.id)

      new_topic = create(:topic, creator_alias: person_alias, created_at: Date.new(2018, 1, 1))
      create(:message, topic: new_topic, sender: person_alias, is_patch_submission: true,
             created_at: Date.new(2018, 1, 1), updated_at: Date.new(2018, 1, 1))
      new_commit = create(:commit)
      create(:commit_topic, commit: new_commit, topic: new_topic)
      CommitPerson.create!(commit: new_commit, role: "author", person_id: person.id)

      stats = described_class.new(person.id)

      expect(stats.patch_threads).to eq(2)
      expect(stats.patch_threads_since_era).to eq(1)
      expect(stats.landed_patch_threads).to eq(1)
      expect(stats.landed_patch_rate).to eq(100)
    end

    it "does not credit a reviewer whose test-case patch sits in someone else's landed thread" do
      owner = create(:person)
      owner_alias = create(:alias, person: owner, email: "owner@example.com")

      topic = create(:topic, creator_alias: owner_alias)
      create(:message, topic: topic, sender: owner_alias, is_patch_submission: true)
      create(:message, topic: topic, sender: person_alias, is_patch_submission: true)

      commit = create(:commit)
      create(:commit_topic, commit: commit, topic: topic)
      CommitPerson.create!(commit: commit, role: "author", person_id: owner.id)
      CommitPerson.create!(commit: commit, role: "reviewer", person_id: person.id)

      expect(described_class.new(owner.id).landed_patch_threads).to eq(1)
      expect(described_class.new(person.id).landed_patch_threads).to eq(0)
      expect(described_class.new(person.id).patch_threads).to eq(1)
    end

    it "credits a maintainer who dropped a test-case patch into someone else's thread and then committed it" do
      # committer is in LANDED_ROLES on purpose: a maintainer who commits a
      # thread's patch gets credit for that thread even if their own
      # contribution to it was just a test case, unlike a plain reviewer
      # (see the test above). This is the chosen outcome, not an oversight -
      # if LANDED_ROLES ever changes, re-check this boundary.
      owner = create(:person)
      owner_alias = create(:alias, person: owner, email: "commit-owner@example.com")

      topic = create(:topic, creator_alias: owner_alias)
      create(:message, topic: topic, sender: owner_alias, is_patch_submission: true)
      create(:message, topic: topic, sender: person_alias, is_patch_submission: true)

      commit = create(:commit)
      create(:commit_topic, commit: commit, topic: topic)
      CommitPerson.create!(commit: commit, role: "author", person_id: owner.id)
      CommitPerson.create!(commit: commit, role: "committer", person_id: person.id)

      expect(described_class.new(person.id).landed_patch_threads).to eq(1)
    end

    it "rounds the rate to a whole percentage" do
      3.times do
        topic = create(:topic, creator_alias: person_alias)
        create(:message, topic: topic, sender: person_alias, is_patch_submission: true)
      end
      # 2 of 3 landed on purpose: 66.67% actually tells round from floor. 1/3
      # rounds to 33 either way and proves nothing.
      landed_topics = Topic.where(creator_person_id: person.id).order(:id).limit(2)
      landed_topics.each do |landed_topic|
        commit = create(:commit)
        create(:commit_topic, commit: commit, topic: landed_topic)
        CommitPerson.create!(commit: commit, role: "author", person_id: person.id)
      end

      stats = described_class.new(person.id)

      expect(stats.patch_threads).to eq(3)
      expect(stats.landed_patch_threads).to eq(2)
      expect(stats.landed_patch_rate).to eq(67)
    end
  end

  describe "commit credits" do
    it "returns zeros for a person with no commits" do
      stats = described_class.new(person.id)

      expect(stats.commit_credits_total).to eq(0)
      expect(stats.commit_credits_by_role).to eq(
        "author" => 0, "reviewer" => 0,
        "reported_by" => 0, "co_author" => 0, "committer" => 0
      )
    end

    it "ignores llm-sourced rows" do
      commit = create(:commit)
      CommitPerson.create!(commit: commit, role: "author", person_id: person.id, source: "llm", confidence: 0.9)

      stats = described_class.new(person.id)

      expect(stats.commit_credits_total).to eq(0)
      expect(stats.commit_credits_by_role["author"]).to eq(0)
    end

    it "counts llm-sourced rows when widened to llm" do
      commit = create(:commit)
      CommitPerson.create!(commit: commit, role: "author", person_id: person.id, source: "llm", confidence: 0.9)

      stats = described_class.new(person.id, sources: %w[parsed llm])

      expect(stats.commit_credits_total).to eq(1)
      expect(stats.commit_credits_by_role["author"]).to eq(1)
    end

    it "counts one commit once even when it credits the person in two roles" do
      commit = create(:commit)
      CommitPerson.create!(commit: commit, role: "author", person_id: person.id)
      CommitPerson.create!(commit: commit, role: "committer", person_id: person.id)

      stats = described_class.new(person.id)

      expect(stats.commit_credits_total).to eq(1)
      expect(stats.commit_credits_by_role["author"]).to eq(1)
      expect(stats.commit_credits_by_role["committer"]).to eq(1)
      expect(stats.commit_credits_by_role.values.sum).to eq(2)
    end

    it "keeps roles in display order, minus tested_by" do
      commit = create(:commit)
      CommitPerson.create!(commit: commit, role: "reviewer", person_id: person.id)

      expect(described_class.new(person.id).commit_credits_by_role.keys).to eq(
        described_class::PROFILE_ROLE_ORDER
      )
      expect(described_class.new(person.id).commit_credits_by_role.keys).not_to include("tested_by")
    end

    it "drops tested_by from the breakdown but keeps it in the hero total" do
      commit = create(:commit)
      CommitPerson.create!(commit: commit, role: "tested_by", person_id: person.id)

      stats = described_class.new(person.id)

      expect(stats.commit_credits_total).to eq(1)
      expect(stats.commit_credits_by_role).not_to have_key("tested_by")
      expect(stats.commit_credits_by_role.values.sum).to eq(0)
    end

    it "counts a shared commit once for a team" do
      other_person = create(:person)
      commit = create(:commit)
      CommitPerson.create!(commit: commit, role: "author", person_id: person.id)
      CommitPerson.create!(commit: commit, role: "reviewer", person_id: other_person.id)

      stats = described_class.new([ person.id, other_person.id ])

      expect(stats.commit_credits_total).to eq(1)
      expect(stats.commit_credits_by_role.values.sum).to eq(2)
    end

    it "does not leak another person's commit credits" do
      outsider = create(:person)
      outsider_commit = create(:commit)
      CommitPerson.create!(commit: outsider_commit, role: "author", person_id: outsider.id)
      CommitPerson.create!(commit: outsider_commit, role: "reviewer", person_id: outsider.id)

      stats = described_class.new(person.id)

      expect(stats.commit_credits_total).to eq(0)
      expect(stats.commit_credits_by_role.values.sum).to eq(0)
    end

    it "counts only the master commit, not its backports, in the hero and role totals" do
      master_commit = create(:commit, branches: [ "master" ])
      CommitPerson.create!(commit: master_commit, role: "author", person_id: person.id)

      backport_commit = create(:commit, branches: [ "REL_17_STABLE" ], cherry_picked_from_sha: master_commit.sha)
      CommitPerson.create!(commit: backport_commit, role: "author", person_id: person.id)

      stats = described_class.new(person.id)

      expect(stats.commit_credits_total).to eq(1)
      expect(stats.commit_credits_by_role["author"]).to eq(1)
    end

    it "excludes a commit that only exists on a stable branch from the totals" do
      stable_only_commit = create(:commit, branches: [ "REL_16_STABLE" ])
      CommitPerson.create!(commit: stable_only_commit, role: "author", person_id: person.id)

      stats = described_class.new(person.id)

      expect(stats.commit_credits_total).to eq(0)
      expect(stats.commit_credits_by_role["author"]).to eq(0)
    end
  end

  describe "backport credits" do
    it "returns zero for a person with no backports" do
      commit = create(:commit, branches: [ "master" ])
      CommitPerson.create!(commit: commit, role: "author", person_id: person.id)

      expect(described_class.new(person.id).backport_credits).to eq(0)
    end

    it "counts a backport commit credited as author" do
      master_commit = create(:commit, branches: [ "master" ])
      backport_commit = create(:commit, branches: [ "REL_17_STABLE" ], cherry_picked_from_sha: master_commit.sha)
      CommitPerson.create!(commit: backport_commit, role: "author", person_id: person.id)

      expect(described_class.new(person.id).backport_credits).to eq(1)
    end

    it "ignores an llm-sourced backport author row" do
      master_commit = create(:commit, branches: [ "master" ])
      backport_commit = create(:commit, branches: [ "REL_17_STABLE" ], cherry_picked_from_sha: master_commit.sha)
      CommitPerson.create!(commit: backport_commit, role: "author", person_id: person.id, source: "llm", confidence: 0.9)

      expect(described_class.new(person.id).backport_credits).to eq(0)
    end

    it "counts an llm-sourced backport author row when widened to llm" do
      master_commit = create(:commit, branches: [ "master" ])
      backport_commit = create(:commit, branches: [ "REL_17_STABLE" ], cherry_picked_from_sha: master_commit.sha)
      CommitPerson.create!(commit: backport_commit, role: "author", person_id: person.id, source: "llm", confidence: 0.9)

      expect(described_class.new(person.id, sources: %w[parsed llm]).backport_credits).to eq(1)
    end

    it "does not count a backport where the person is only credited as reviewer" do
      master_commit = create(:commit, branches: [ "master" ])
      backport_commit = create(:commit, branches: [ "REL_17_STABLE" ], cherry_picked_from_sha: master_commit.sha)
      CommitPerson.create!(commit: backport_commit, role: "reviewer", person_id: person.id)

      expect(described_class.new(person.id).backport_credits).to eq(0)
    end

    it "does not count a backport where the person is only credited as committer" do
      master_commit = create(:commit, branches: [ "master" ])
      backport_commit = create(:commit, branches: [ "REL_17_STABLE" ], cherry_picked_from_sha: master_commit.sha)
      CommitPerson.create!(commit: backport_commit, role: "committer", person_id: person.id)

      expect(described_class.new(person.id).backport_credits).to eq(0)
    end

    it "does not count the master commit itself, only its backports" do
      master_commit = create(:commit, branches: [ "master" ])
      CommitPerson.create!(commit: master_commit, role: "author", person_id: person.id)

      expect(described_class.new(person.id).backport_credits).to eq(0)
    end

    it "counts two backports of the same change as two backport credits" do
      master_commit = create(:commit, branches: [ "master" ])
      backport_a = create(:commit, branches: [ "REL_17_STABLE" ], cherry_picked_from_sha: master_commit.sha)
      backport_b = create(:commit, branches: [ "REL_16_STABLE" ], cherry_picked_from_sha: master_commit.sha)
      CommitPerson.create!(commit: backport_a, role: "author", person_id: person.id)
      CommitPerson.create!(commit: backport_b, role: "author", person_id: person.id)

      expect(described_class.new(person.id).backport_credits).to eq(2)
    end
  end

  describe "started threads" do
    it "returns zeros and nil threads when the person started nothing" do
      stats = described_class.new(person.id)

      expect(stats.threads_started).to eq(0)
      expect(stats.threads_without_reply).to eq(0)
      expect(stats.median_thread_lifetime_days).to be_nil
      expect(stats.longest_running_thread).to be_nil
      expect(stats.most_participants_thread).to be_nil
      expect(stats.most_messages_thread).to be_nil
    end

    it "memoizes a nil notable thread instead of re-querying" do
      stats = described_class.new(person.id)
      stats.longest_running_thread

      expect(captured_queries { stats.longest_running_thread }).to be_empty
    end

    it "counts threads and threads that never got a reply" do
      quiet = create(:topic, creator_alias: person_alias, created_at: Time.utc(2024, 1, 1))
      create(:message, topic: quiet, sender: person_alias,
             created_at: Time.utc(2024, 1, 1), updated_at: Time.utc(2024, 1, 1))

      busy = create(:topic, creator_alias: person_alias, created_at: Time.utc(2024, 1, 1))
      create(:message, topic: busy, sender: person_alias,
             created_at: Time.utc(2024, 1, 1), updated_at: Time.utc(2024, 1, 1))
      create(:message, topic: busy, sender: person_alias,
             created_at: Time.utc(2024, 1, 11), updated_at: Time.utc(2024, 1, 11))

      stats = described_class.new(person.id)

      expect(stats.threads_started).to eq(2)
      expect(stats.threads_without_reply).to eq(1)
    end

    it "interpolates the median lifetime over an even number of threads" do
      # Skewed on purpose: median 2.5, mean 26.5. A fixture where median and mean
      # coincide (like the old [2, 8]) can't tell percentile_cont from avg.
      [ 1, 2, 3, 100 ].each do |days|
        topic = create(:topic, creator_alias: person_alias, created_at: Time.utc(2024, 1, 1))
        create(:message, topic: topic, sender: person_alias,
               created_at: Time.utc(2024, 1, 1), updated_at: Time.utc(2024, 1, 1))
        create(:message, topic: topic, sender: person_alias,
               created_at: Time.utc(2024, 1, 1) + days.days, updated_at: Time.utc(2024, 1, 1) + days.days)
      end

      expect(described_class.new(person.id).median_thread_lifetime_days).to be_within(0.01).of(2.5)
    end

    it "treats a null last_message_at as a zero-length thread" do
      topic = create(:topic, creator_alias: person_alias, created_at: Time.utc(2024, 1, 1))
      topic.update_columns(last_message_at: nil)

      stats = described_class.new(person.id)

      expect(stats.threads_started).to eq(1)
      expect(stats.median_thread_lifetime_days).to eq(0.0)
    end

    it "finds the longest running, most participated and most messaged threads" do
      other_alias = create(:alias, person: create(:person), email: "third@example.com")

      long = create(:topic, creator_alias: person_alias, title: "Long one",
                    created_at: Time.utc(2020, 1, 1))
      create(:message, topic: long, sender: person_alias,
             created_at: Time.utc(2020, 1, 1), updated_at: Time.utc(2020, 1, 1))
      create(:message, topic: long, sender: person_alias,
             created_at: Time.utc(2023, 1, 1), updated_at: Time.utc(2023, 1, 1))

      crowded = create(:topic, creator_alias: person_alias, title: "Crowded one",
                       created_at: Time.utc(2024, 1, 1))
      create(:message, topic: crowded, sender: person_alias,
             created_at: Time.utc(2024, 1, 1), updated_at: Time.utc(2024, 1, 1))
      create(:message, topic: crowded, sender: other_alias,
             created_at: Time.utc(2024, 1, 2), updated_at: Time.utc(2024, 1, 2))

      chatty = create(:topic, creator_alias: person_alias, title: "Chatty one",
                      created_at: Time.utc(2024, 2, 1))
      4.times do |i|
        create(:message, topic: chatty, sender: person_alias,
               created_at: Time.utc(2024, 2, 1) + i.days, updated_at: Time.utc(2024, 2, 1) + i.days)
      end

      stats = described_class.new(person.id)

      expect(stats.longest_running_thread.title).to eq("Long one")
      expect(stats.most_participants_thread.title).to eq("Crowded one")
      expect(stats.most_messages_thread.title).to eq("Chatty one")
    end

    it "reports how long the longest running thread ran" do
      long = create(:topic, creator_alias: person_alias, created_at: Time.utc(2020, 1, 1))
      create(:message, topic: long, sender: person_alias,
             created_at: Time.utc(2020, 1, 1), updated_at: Time.utc(2020, 1, 1))
      create(:message, topic: long, sender: person_alias,
             created_at: Time.utc(2020, 1, 11), updated_at: Time.utc(2020, 1, 11))

      expect(described_class.new(person.id).longest_running_thread_days).to be_within(0.01).of(10.0)
    end

    it "has no longest running duration without threads" do
      expect(described_class.new(person.id).longest_running_thread_days).to be_nil
    end

    it "falls back to created_at for the duration when last_message_at is null" do
      topic = create(:topic, creator_alias: person_alias, created_at: Time.utc(2024, 1, 1))
      create(:message, topic: topic, sender: person_alias,
             created_at: Time.utc(2024, 1, 1), updated_at: Time.utc(2024, 1, 1))
      topic.update_columns(last_message_at: nil)

      expect(described_class.new(person.id).longest_running_thread_days).to eq(0.0)
    end

    it "does not let a null last_message_at outrank a genuinely long-running thread" do
      long = create(:topic, creator_alias: person_alias, title: "Genuinely long",
                    created_at: Time.utc(2015, 1, 1))
      create(:message, topic: long, sender: person_alias,
             created_at: Time.utc(2015, 1, 1), updated_at: Time.utc(2015, 1, 1))
      create(:message, topic: long, sender: person_alias,
             created_at: Time.utc(2020, 1, 1), updated_at: Time.utc(2020, 1, 1))

      nulled = create(:topic, creator_alias: person_alias, title: "Null last message at",
                      created_at: Time.utc(2024, 1, 1))
      create(:message, topic: nulled, sender: person_alias,
             created_at: Time.utc(2024, 1, 1), updated_at: Time.utc(2024, 1, 1))
      nulled.update_columns(last_message_at: nil)

      expect(described_class.new(person.id).longest_running_thread.title).to eq("Genuinely long")
    end

    it "does not leak another person's threads into any started-thread stat" do
      outsider = create(:person)
      outsider_alias = create(:alias, person: outsider, email: "outsider-started@example.com")
      outsider_friend = create(:alias, person: create(:person), email: "outsider-friend@example.com")

      # Outsider's thread out-ranks the person's on every notable-thread dimension:
      # longer running, more participants, more messages.
      dominant = create(:topic, creator_alias: outsider_alias, title: "Outsider dominant thread",
                        created_at: Time.utc(2000, 1, 1))
      6.times do |i|
        create(:message, topic: dominant, sender: outsider_alias,
               created_at: Time.utc(2000, 1, 1) + i.days, updated_at: Time.utc(2000, 1, 1) + i.days)
      end
      create(:message, topic: dominant, sender: outsider_friend,
             created_at: Time.utc(2000, 1, 10), updated_at: Time.utc(2000, 1, 10))

      mine = create(:topic, creator_alias: person_alias, title: "Mine", created_at: Time.utc(2024, 1, 1))
      create(:message, topic: mine, sender: person_alias,
             created_at: Time.utc(2024, 1, 1), updated_at: Time.utc(2024, 1, 1))

      stats = described_class.new(person.id)

      expect(stats.threads_started).to eq(1)
      expect(stats.threads_without_reply).to eq(1)
      expect(stats.median_thread_lifetime_days).to eq(0.0)
      expect(stats.longest_running_thread.title).to eq("Mine")
      expect(stats.most_participants_thread.title).to eq("Mine")
      expect(stats.most_messages_thread.title).to eq("Mine")
    end

    it "breaks ties on id for every notable thread" do
      other_alias = create(:alias, person: create(:person), email: "tie-friend@example.com")

      first = create(:topic, creator_alias: person_alias, title: "First tied", created_at: Time.utc(2024, 1, 1))
      second = create(:topic, creator_alias: person_alias, title: "Second tied", created_at: Time.utc(2024, 1, 1))

      [ first, second ].each do |topic|
        create(:message, topic: topic, sender: person_alias,
               created_at: Time.utc(2024, 1, 1), updated_at: Time.utc(2024, 1, 1))
        create(:message, topic: topic, sender: other_alias,
               created_at: Time.utc(2024, 1, 5), updated_at: Time.utc(2024, 1, 5))
      end

      expect(first.id).to be < second.id

      3.times do
        stats = described_class.new(person.id)
        expect(stats.longest_running_thread.id).to eq(first.id)
        expect(stats.most_participants_thread.id).to eq(first.id)
        expect(stats.most_messages_thread.id).to eq(first.id)
      end
    end
  end

  describe "total query budget" do
    it "loads every public stat in eleven queries" do
      topic = create(:topic, creator_alias: person_alias, created_at: Date.new(2018, 1, 1))
      create(:message, topic: topic, sender: person_alias, is_patch_submission: true,
             created_at: Date.new(2018, 1, 1), updated_at: Date.new(2018, 1, 1))
      commit = create(:commit)
      create(:commit_topic, commit: commit, topic: topic)
      CommitPerson.create!(commit: commit, role: "committer", person_id: person.id)

      other = create(:topic, creator_alias: person_alias, created_at: 3.days.ago)
      create(:message, topic: other, sender: person_alias, created_at: 3.days.ago, updated_at: 3.days.ago)

      stats = described_class.new(person.id)

      queries = captured_queries do
        stats.messages_sent
        stats.first_message_at
        stats.last_message_at
        stats.years_active
        stats.threads_joined
        stats.patches_sent
        stats.patch_threads
        stats.patch_threads_since_era
        stats.landed_patch_threads
        stats.landed_patch_rate
        stats.commit_credits_total
        stats.commit_credits_by_role
        stats.backport_credits
        stats.threads_started
        stats.threads_without_reply
        stats.median_thread_lifetime_days
        stats.longest_running_thread
        stats.most_participants_thread
        stats.most_messages_thread
      end

      expect(queries.size).to eq(11)
    end
  end
end
