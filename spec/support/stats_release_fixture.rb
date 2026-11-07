# A tiny PG19 cycle, numbers chosen so every Overview tile has a known value.
#
# Tags: REL_18_BETA1 2025-05-05, REL_18_0 2025-09-22, REL_19_BETA1 2026-06-01.
# People: alice (committer), dave (committer), bob, carol (never committed).
# Scope commits (4): c1, c2, c3, c4b. Excluded: c3b (18 backport), c4 (master
# only, post-branch), c4c (18 member of the c4 group), c4d (second 19
# cherry-pick of c4, collapsed into c4b), c5 (pre-branch, in 18 too).
# Backported groups (2): c3 (via c3b) and c4 (via c4c).
#   c1  2025-10-10 alice commits bob's patch, carol reviews (parsed), thread t1
#       (created 2025-09-01), verdict as_is, chain of 3 versions, CF entry,
#       +100/-10 lines, files a.c b.c
#   c2  2026-01-15 alice, no Author credit, subject "Revert ...", thread t2
#       (created 2025-12-01), verdict modified/light, llm-only review, CF entry,
#       +5/-5 lines, file a.c
#   c3  2026-02-01 dave, canonical, backported to 18 as c3b, no thread,
#       +20/-0, file c.c
#   c4b 2026-07-01 on REL_19_STABLE only, cherry-pick of c4, alice commits
#       dave's patch, thread t4 (created 2026-06-20, no messages), no
#       reviewer, +7/-3, file d.c; its verdict (as_is, no reviews) sits on
#       the master commit c4, matched by backport group
# Verdicts that must not count: c1 modified/moderate in an older t1 run, c3
# not_this_thread in run2.
#   c4c 2026-07-01 13:00 REL_18_STABLE cherry-pick of c4, otherwise as c4b
#   c4d 2026-07-02 REL_19_STABLE cherry-pick of c4, otherwise as c4b
# Messages in t1: 5 (2025-09-01 bob patch mail, 2025-09-10 carol reply,
# 2025-09-25 bob reply in the middle phase, 2025-10-01 and 2025-10-05 bob
# patch mails); in t2: 2 (2025-12-01 alice, 2025-12-05 bob); unrelated
# thread t3 with 1 message on 2026-03-01 (middle phase, not a release thread)
# and 1 message on 2025-06-01 (early phase, not a release thread).
# Affiliations (since..until, nil = open):
#   alice  Acme       2025-01-01..nil         contributors_page
#   carol  Acme       nil..nil                domain
#   bob    Beta Corp  nil..2025-11-30         domain
#   bob    Gamma      2025-12-01..nil         manual
#   dave   none
# Only the time windows see these (release numbers do not move):
#   c6  2026-03-01 REL_18_STABLE only, dave, +2/-2, file f.c: a back-branch-only fix
#   c7  2024-12-01 master (in 17, 18, 19 too), alice, +3/-1, file g.c
#   c7b 2026-01-10 REL_16_STABLE cherry-pick of c7: an old change backported in 2026
#   c4 is linked to t4 like c4b, as the importer links every commit with the trailer
# Year 2026: c2 c3 c4 c6, backported c3 c4. Year 2025: c1 c5.
# Cycle 2025 (18 beta1 to 19 beta1): c1 c2 c3 c6, backported c3. Cycle 2026: c4.
module StatsReleaseFixture
  Built = Struct.new(:people, :commits, :topics, :messages, :cf_patch, :affiliations, keyword_init: true)

  def build_stats_release_fixture
    create(:release_tag, name: "REL_18_BETA1", released_at: Time.zone.parse("2025-05-05 20:00"))
    create(:release_tag, name: "REL_18_0", released_at: Time.zone.parse("2025-09-22 20:00"))
    create(:release_tag, name: "REL_19_BETA1", released_at: Time.zone.parse("2026-06-01 20:00"))

    people = {}
    %w[alice dave bob carol].each do |name|
      a = create(:alias, name: name.capitalize, email: "#{name}@example.com")
      people[name] = a.person
    end

    t1 = create(:topic, title: "t1 patch", creator_alias: people["bob"].default_alias, created_at: Time.zone.parse("2025-09-01"))
    t2 = create(:topic, title: "t2 fix", creator_alias: people["alice"].default_alias, created_at: Time.zone.parse("2025-12-01"))
    t3 = create(:topic, title: "t3 unrelated", creator_alias: people["carol"].default_alias, created_at: Time.zone.parse("2025-06-01"))
    t4 = create(:topic, title: "t4 stabilization", creator_alias: people["alice"].default_alias, created_at: Time.zone.parse("2026-06-20"))

    m = {}
    m[:t1_v1] = create(:message, topic: t1, sender_alias: people["bob"].default_alias, is_patch_submission: true, created_at: Time.zone.parse("2025-09-01 10:00"))
    m[:t1_rev] = create(:message, topic: t1, sender_alias: people["carol"].default_alias, reply_to: m[:t1_v1], created_at: Time.zone.parse("2025-09-10 10:00"))
    m[:t1_mid] = create(:message, topic: t1, sender_alias: people["bob"].default_alias, reply_to: m[:t1_rev], created_at: Time.zone.parse("2025-09-25 10:00"))
    m[:t1_v2] = create(:message, topic: t1, sender_alias: people["bob"].default_alias, is_patch_submission: true, reply_to: m[:t1_rev], created_at: Time.zone.parse("2025-10-01 10:00"))
    m[:t1_v3] = create(:message, topic: t1, sender_alias: people["bob"].default_alias, is_patch_submission: true, reply_to: m[:t1_v2], created_at: Time.zone.parse("2025-10-05 10:00"))
    m[:t2_root] = create(:message, topic: t2, sender_alias: people["alice"].default_alias, created_at: Time.zone.parse("2025-12-01 10:00"))
    m[:t2_reply] = create(:message, topic: t2, sender_alias: people["bob"].default_alias, reply_to: m[:t2_root], created_at: Time.zone.parse("2025-12-05 10:00"))
    m[:t3_early] = create(:message, topic: t3, sender_alias: people["carol"].default_alias, created_at: Time.zone.parse("2025-06-01 10:00"))
    m[:t3_mid] = create(:message, topic: t3, sender_alias: people["carol"].default_alias, created_at: Time.zone.parse("2026-03-01 10:00"))

    c = {}
    c[:c1] = create(:commit, sha: "1" * 40, subject: "Add thing", committed_at: Time.zone.parse("2025-10-10 12:00"),
                             branches: %w[REL_19_STABLE master], committer_name: "Alice", committer_email: "alice@example.com",
                             lines_added: 100, lines_removed: 10)
    c[:c2] = create(:commit, sha: "2" * 40, subject: "Revert \"Add thing\" partially", committed_at: Time.zone.parse("2026-01-15 12:00"),
                             branches: %w[REL_19_STABLE master], committer_name: "Alice", committer_email: "alice@example.com",
                             lines_added: 5, lines_removed: 5)
    c[:c3] = create(:commit, sha: "3" * 40, subject: "Fix bug", committed_at: Time.zone.parse("2026-02-01 12:00"),
                             branches: %w[REL_19_STABLE master], committer_name: "Dave", committer_email: "dave@example.com",
                             lines_added: 20, lines_removed: 0)
    c[:c3b] = create(:commit, sha: "b" * 40, subject: "Fix bug", committed_at: Time.zone.parse("2026-02-01 12:30"),
                              branches: %w[REL_18_STABLE], cherry_picked_from_sha: c[:c3].sha, committer_name: "Dave", committer_email: "dave@example.com",
                              lines_added: 20, lines_removed: 0)
    c[:c4] = create(:commit, sha: "4" * 40, subject: "Stabilize", committed_at: Time.zone.parse("2026-07-01 12:00"),
                             branches: %w[master], committer_name: "Alice", committer_email: "alice@example.com",
                             lines_added: 7, lines_removed: 3)
    c[:c4b] = create(:commit, sha: "c" * 40, subject: "Stabilize", committed_at: Time.zone.parse("2026-07-01 12:30"),
                              branches: %w[REL_19_STABLE], cherry_picked_from_sha: c[:c4].sha, committer_name: "Alice", committer_email: "alice@example.com",
                              lines_added: 7, lines_removed: 3)
    c[:c4c] = create(:commit, sha: "d" * 40, subject: "Stabilize", committed_at: Time.zone.parse("2026-07-01 13:00"),
                              branches: %w[REL_18_STABLE], cherry_picked_from_sha: c[:c4].sha, committer_name: "Alice", committer_email: "alice@example.com",
                              lines_added: 7, lines_removed: 3)
    c[:c4d] = create(:commit, sha: "e" * 40, subject: "Stabilize", committed_at: Time.zone.parse("2026-07-02 12:00"),
                              branches: %w[REL_19_STABLE], cherry_picked_from_sha: c[:c4].sha, committer_name: "Alice", committer_email: "alice@example.com",
                              lines_added: 7, lines_removed: 3)
    c[:c5] = create(:commit, sha: "5" * 40, subject: "Old thing", committed_at: Time.zone.parse("2025-04-01 12:00"),
                             branches: %w[REL_18_STABLE REL_19_STABLE master], committer_name: "Alice", committer_email: "alice@example.com",
                             lines_added: 1, lines_removed: 1)
    c[:c6] = create(:commit, sha: "6" * 40, subject: "Back-branch only fix", committed_at: Time.zone.parse("2026-03-01 12:00"),
                             branches: %w[REL_18_STABLE], committer_name: "Dave", committer_email: "dave@example.com",
                             lines_added: 2, lines_removed: 2)
    c[:c7] = create(:commit, sha: "7" * 40, subject: "Old master thing", committed_at: Time.zone.parse("2024-12-01 12:00"),
                             branches: %w[REL_17_STABLE REL_18_STABLE REL_19_STABLE master], committer_name: "Alice", committer_email: "alice@example.com",
                             lines_added: 3, lines_removed: 1)
    c[:c7b] = create(:commit, sha: "f" * 40, subject: "Old master thing", committed_at: Time.zone.parse("2026-01-10 12:00"),
                              branches: %w[REL_16_STABLE], cherry_picked_from_sha: c[:c7].sha, committer_name: "Alice", committer_email: "alice@example.com",
                              lines_added: 3, lines_removed: 1)

    { c1: %w[a.c b.c], c2: %w[a.c], c3: %w[c.c], c3b: %w[c.c], c4: %w[d.c], c4b: %w[d.c], c4c: %w[d.c], c4d: %w[d.c], c5: %w[e.c], c6: %w[f.c], c7: %w[g.c], c7b: %w[g.c] }.each do |key, paths|
      paths.each { |path| CommitFile.create!(commit: c[key], path: path) }
    end

    credit = ->(commit, person, role) { create(:commit_person, commit: commit, person: person, role: role, raw_name: person.display_name, raw_email: person.default_alias.email) }
    committer = CommitPerson::COMMITTER
    credit.call(c[:c1], people["alice"], committer); credit.call(c[:c1], people["bob"], "author"); credit.call(c[:c1], people["carol"], "reviewer")
    credit.call(c[:c2], people["alice"], committer)
    credit.call(c[:c3], people["dave"], committer); credit.call(c[:c3b], people["dave"], committer)
    %i[c4 c4b c4c c4d].each { |key| credit.call(c[key], people["alice"], committer); credit.call(c[key], people["dave"], "author") }
    credit.call(c[:c5], people["alice"], committer)
    credit.call(c[:c6], people["dave"], committer); credit.call(c[:c7], people["alice"], committer); credit.call(c[:c7b], people["alice"], committer)
    CommitterReviewer.sync!(c.values.map(&:id))

    create(:commit_topic, commit: c[:c1], topic: t1)
    create(:commit_topic, commit: c[:c2], topic: t2)
    create(:commit_topic, commit: c[:c4b], topic: t4)
    create(:commit_topic, commit: c[:c4], topic: t4)

    # an older run on t1 whose verdict would win the tie on id if it counted
    old1 = create(:patchset_run, topic: t1, created_at: 1.day.ago)
    create(:commit_verdict, patchset_run: old1, topic: t1, commit: c[:c1], verdict: "modified", change_level: "moderate", source_message: nil, confidence: 1.0,
                            reviewers_final: 0, reviewers_earlier: 0, reviewers_none: 0, reviews: [])
    run1 = create(:patchset_run, topic: t1)
    create(:patchset_lineage, patchset_run: run1, topic: t1, message: m[:t1_v1], step_kind: "new_series")
    create(:patchset_lineage, patchset_run: run1, topic: t1, message: m[:t1_v2], parent_message: m[:t1_v1], step_kind: "minor_revision")
    create(:patchset_lineage, patchset_run: run1, topic: t1, message: m[:t1_v3], parent_message: m[:t1_v2], step_kind: "rebase")
    create(:commit_verdict, patchset_run: run1, topic: t1, commit: c[:c1], verdict: "as_is", source_message: m[:t1_v3], confidence: 1.0,
                            reviewers_final: 1, reviewers_earlier: 0, reviewers_none: 0,
                            reviews: [ { "reviewer" => "Carol", "source" => "trailer", "coverage" => "final", "reviewed_message_ids" => [ m[:t1_v3].id ], "note" => "" },
                                       { "reviewer" => "Alice", "source" => "committer", "coverage" => "final", "reviewed_message_ids" => [], "note" => "committed the patch" } ])
    run2 = create(:patchset_run, topic: t2)
    create(:commit_verdict, patchset_run: run2, topic: t2, commit: c[:c2], verdict: "modified", change_level: "light", source_message: nil, confidence: 0.9,
                            reviewers_final: 1, reviewers_earlier: 0, reviewers_none: 0,
                            reviews: [ { "reviewer" => "Bob", "source" => "llm", "coverage" => "final", "reviewed_message_ids" => [], "note" => "tested", "confidence" => 0.9 } ])

    run4 = create(:patchset_run, topic: t4)
    create(:commit_verdict, patchset_run: run4, topic: t4, commit: c[:c4], verdict: "as_is", source_message: nil, confidence: 1.0,
                            reviewers_final: 0, reviewers_earlier: 0, reviewers_none: 0, reviews: [])

    create(:commit_verdict, patchset_run: run2, topic: t2, commit: c[:c3], verdict: "not_this_thread", source_message: nil, confidence: 1.0,
                            reviewers_final: 0, reviewers_earlier: 0, reviewers_none: 0, reviews: [])

    cf = create(:commitfest_patch, title: "Add thing")
    create(:commitfest_patch_topic, commitfest_patch: cf, topic: t1)
    create(:commitfest_patch_topic, commitfest_patch: cf, topic: t2)

    affiliations = [
      PersonAffiliation.create!(person: people["alice"], company: "Acme", since: Date.new(2025, 1, 1), source: "contributors_page"),
      PersonAffiliation.create!(person: people["carol"], company: "Acme", source: "domain"),
      PersonAffiliation.create!(person: people["bob"], company: "Beta Corp", until: Date.new(2025, 11, 30), source: "domain"),
      PersonAffiliation.create!(person: people["bob"], company: "Gamma", since: Date.new(2025, 12, 1), source: "manual")
    ]

    Built.new(people: people, commits: c, topics: { t1: t1, t2: t2, t3: t3, t4: t4 }, messages: m, cf_patch: cf,
              affiliations: affiliations)
  end
end

RSpec.configure do |config|
  config.include StatsReleaseFixture
end
