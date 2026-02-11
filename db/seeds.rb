require "base64"

unless Rails.env.development?
  puts "Skipping seeds: intended for development only."
  return
end

puts "Resetting development data..."

ApplicationRecord.transaction do
  Activity.delete_all
  NoteEdit.delete_all
  NoteTag.delete_all
  NoteMention.delete_all
  Note.delete_all
  Mention.delete_all
  PatchFile.delete_all
  Attachment.delete_all
  MessageReadRange.delete_all
  ThreadAwareness.delete_all
  Message.delete_all
  Topic.delete_all
  TeamMember.delete_all
  Team.delete_all
  Alias.delete_all
  Person.delete_all
  NameReservation.delete_all
  User.delete_all
end

now = Time.zone.now
password = "password"

def create_user_with_alias(username:, name:, email:, admin: false, verified: true, password:)
  person = Person.create!
  user = User.create!(
    username:,
    admin:,
    person:,
    password:,
    password_confirmation: password
  )

  ali = Alias.create!(
    user:,
    person:,
    name:,
    email:,
    verified_at: verified ? Time.current : nil
  )
  person.update!(default_alias_id: ali.id)

  [ user, ali ]
end

alice_user, alice_alias = create_user_with_alias(
  username: "alice_core",
  name: "Alice Core",
  email: "alice_core@example.com",
  admin: true,
  password: password
)

bob_user, bob_alias = create_user_with_alias(
  username: "bob_committer",
  name: "Bob Committer",
  email: "bob_committer@example.com",
  password: password
)

carol_user, carol_alias = create_user_with_alias(
  username: "carol_contributor",
  name: "Carol Contributor",
  email: "carol_contributor@example.com",
  password: password
)

dave_user, dave_alias = create_user_with_alias(
  username: "dave_new",
  name: "Dave New",
  email: "dave_new@example.com",
  password: password
)

legacy_alias = Alias.create!(
  person: Person.create!,
  name: "Legacy Poster",
  email: "legacy@oldmail.example",
  verified_at: nil
)
legacy_alias.person.update!(default_alias_id: legacy_alias.id)

ci_bot_alias = Alias.create!(
  person: Person.create!,
  name: "Build Bot",
  email: "buildbot@ci.example",
  verified_at: now
)
ci_bot_alias.person.update!(default_alias_id: ci_bot_alias.id)

# Contributor roles assigned to people
ContributorMembership.create!(person: alice_user.person, contributor_type: :core_team, name: alice_alias.name)
ContributorMembership.create!(person: bob_user.person, contributor_type: :committer, name: bob_alias.name)
ContributorMembership.create!(person: carol_user.person, contributor_type: :significant_contributor, name: carol_alias.name)
ContributorMembership.create!(person: legacy_alias.person, contributor_type: :past_major_contributor, name: legacy_alias.name)

# Independent team (not tied to contributors)
example_team = Team.create!(name: "ExampleCompany")
TeamMember.add_member(team: example_team, user: alice_user, role: :admin)
TeamMember.add_member(team: example_team, user: bob_user, role: :member)
TeamMember.add_member(team: example_team, user: carol_user, role: :member)

# Reserve mention handles for team sharing
NameReservation.reserve!(name: example_team.name, owner: example_team)
NameReservation.reserve!(name: alice_user.username, owner: alice_user)
NameReservation.reserve!(name: bob_user.username, owner: bob_user)
NameReservation.reserve!(name: carol_user.username, owner: carol_user)

# Topics and messages
base_time = now - 20.days

def create_message(topic:, sender:, subject:, body:, created_at:, reply_to: nil, message_id_suffix:)
  Message.create!(
    topic:,
    sender:,
    sender_person: sender.person,
    reply_to:,
    subject:,
    body:,
    message_id: "#{message_id_suffix}@hackorum.dev",
    created_at:,
    updated_at: created_at
  )
end

def mark_all_read(user:, topic:, timestamp:)
  first_id = topic.messages.minimum(:id)
  last_id = topic.messages.maximum(:id)
  return unless first_id && last_id

  MessageReadRange.add_range(
    user:,
    topic:,
    start_id: first_id,
    end_id: last_id,
    read_at: timestamp
  )
end

def mark_read_until(user:, topic:, message:, timestamp:)
  first_id = topic.messages.minimum(:id)
  return unless first_id && message

  MessageReadRange.add_range(
    user:,
    topic:,
    start_id: first_id,
    end_id: message.id,
    read_at: timestamp
  )
end

def mark_aware_until(user:, topic:, message:, timestamp:)
  return unless message
  ThreadAwareness.mark_until(
    user:,
    topic:,
    until_message_id: message.id,
    aware_at: timestamp
  )
end

# 1) Patch thread
patch_topic = Topic.create!(
  title: "Add VACUUM progress tracking",
  creator: bob_alias,
  creator_person: bob_alias.person,
  created_at: base_time,
  updated_at: base_time
)

msg1 = create_message(
  topic: patch_topic,
  sender: bob_alias,
  subject: patch_topic.title,
  body: <<~BODY,
    Proposal to add a lightweight progress tracker to VACUUM operations so we can expose it via pg_stat_progress_vacuum.

    See attached patch for a first cut.
  BODY
  created_at: base_time,
  message_id_suffix: "vacuum-progress-1"
)

patch_content = <<~PATCH
  diff --git a/src/backend/commands/vacuum.c b/src/backend/commands/vacuum.c
  index 1111111..2222222 100644
  --- a/src/backend/commands/vacuum.c
  +++ b/src/backend/commands/vacuum.c
  @@
   void
   vacuum_rel(Oid relid, VacuumParams *params)
   {
  +    VacuumProgress progress = {0};
  +    progress.relid = relid;
  +
  +    pgstat_report_vacuum_progress(&progress);
       /* existing logic */
   }
PATCH

patch_attachment = Attachment.create!(
  message: msg1,
  file_name: "0001-add-vacuum-progress.patch",
  content_type: "text/x-patch",
  body: Base64.encode64(patch_content),
  created_at: base_time,
  updated_at: base_time
)

PatchFile.create!(
  attachment: patch_attachment,
  filename: "src/backend/commands/vacuum.c",
  status: "modified"
)

msg2 = create_message(
  topic: patch_topic,
  sender: carol_alias,
  subject: "Re: #{patch_topic.title}",
  body: <<~BODY,
    Nice direction! Two questions:
    - Do we want to expose heap/idx counters separately?
    - Should autovacuum report the same way?

    Suggested change to keep heap vs idx separate:
    --- a/src/backend/commands/vacuum.c
    +++ b/src/backend/commands/vacuum.c
    @@
     -    progress.relnamespace = get_namespace_name(RelationGetNamespace(onerel));
     +    progress.relnamespace = get_namespace_name(RelationGetNamespace(onerel));
    +    progress.heap_blocks_total = onerel->rd_rel->relpages;
    +    progress.index_blocks_total = idx ? idx->rd_rel->relpages : 0;
  BODY
  created_at: base_time + 1.day,
  reply_to: msg1,
  message_id_suffix: "vacuum-progress-2"
)

msg3 = create_message(
  topic: patch_topic,
  sender: alice_alias,
  subject: "Re: #{patch_topic.title}",
  body: <<~BODY,
    Thanks for posting. Let's add WAL position to the progress report so replication monitoring can piggyback.
    Once that's in, I'm +1 to move forward.

    Inline tweak (just the lines to add/remove):
    - progress.wal_lsn = InvalidXLogRecPtr;
    + progress.wal_lsn = GetFlushRecPtr();
  BODY
  created_at: base_time + 2.days,
  reply_to: msg2,
  message_id_suffix: "vacuum-progress-3"
)

Activity.create!(
  user: bob_user,
  activity_type: "topic_created",
  subject: patch_topic,
  payload: { title: patch_topic.title },
  created_at: base_time,
  updated_at: base_time
)

Activity.create!(
  user: bob_user,
  activity_type: "patch_uploaded",
  subject: patch_attachment,
  payload: { filename: patch_attachment.file_name, topic_id: patch_topic.id },
  created_at: base_time,
  updated_at: base_time
)

Activity.create!(
  user: alice_user,
  activity_type: "review_feedback",
  subject: msg3,
  payload: { decision: "needs-updates", topic_id: patch_topic.id },
  created_at: base_time + 2.days,
  updated_at: base_time + 2.days
)

# 2) RFC thread
rfc_topic = Topic.create!(
  title: "RFC: New index AM hooks",
  creator: carol_alias,
  creator_person: carol_alias.person,
  created_at: base_time + 3.days,
  updated_at: base_time + 3.days
)

rfc_msg1 = create_message(
  topic: rfc_topic,
  sender: carol_alias,
  subject: rfc_topic.title,
  body: "Draft hooks for index AM extensions. Looking for design feedback before patching.",
  created_at: base_time + 3.days,
  message_id_suffix: "index-hooks-1"
)

rfc_msg2 = create_message(
  topic: rfc_topic,
  sender: alice_alias,
  subject: "Re: #{rfc_topic.title}",
  body: <<~BODY,
    > Draft hooks for index AM extensions. Looking for design feedback before patching.
    > - Carol

    This seems promising. Please include a sample AM to illustrate the API, and add docs to SGML.

    Inline replies:
    > Expose hook X?
    I'd start small: plug in only the build path, leave vacuum in a follow-up. [1]
    > Document placement?
    SGML in indexam.sgml + a short README in contrib sample.

    [1]: https://example.com/design-notes
  BODY
  created_at: base_time + 4.days,
  reply_to: rfc_msg1,
  message_id_suffix: "index-hooks-2"
)

Activity.create!(
  user: carol_user,
  activity_type: "topic_created",
  subject: rfc_topic,
  payload: { title: rfc_topic.title },
  created_at: base_time + 3.days,
  updated_at: base_time + 3.days
)

# 3) Resolved thread
resolved_topic = Topic.create!(
  title: "Fix TOAST corruption edge case",
  creator: alice_alias,
  creator_person: alice_alias.person,
  created_at: base_time + 5.days,
  updated_at: base_time + 5.days
)

resolved_msg1 = create_message(
  topic: resolved_topic,
  sender: alice_alias,
  subject: resolved_topic.title,
  body: "Patch applied to master and REL_17_STABLE. Marking resolved.",
  created_at: base_time + 5.days,
  message_id_suffix: "toast-fix-1"
)

Activity.create!(
  user: alice_user,
  activity_type: "topic_resolved",
  subject: resolved_topic,
  payload: { resolution: "merged" },
  created_at: base_time + 5.days,
  updated_at: base_time + 5.days
)

# 4) Bot/no-user thread
bot_topic = Topic.create!(
  title: "Build failed on CI",
  creator: ci_bot_alias,
  creator_person: ci_bot_alias.person,
  created_at: base_time + 6.days,
  updated_at: base_time + 6.days
)

create_message(
  topic: bot_topic,
  sender: ci_bot_alias,
  subject: bot_topic.title,
  body: "CI job 4821 failed on REL_17 with clang; see https://ci.example.com/job/4821.",
  created_at: base_time + 6.days,
  message_id_suffix: "ci-fail-1"
)

# 5) Longer discussion with awareness
discussion_topic = Topic.create!(
  title: "Logical replication improvements",
  creator: legacy_alias,
  creator_person: legacy_alias.person,
  created_at: base_time + 7.days,
  updated_at: base_time + 7.days
)

disc_msg1 = create_message(
  topic: discussion_topic,
  sender: legacy_alias,
  subject: discussion_topic.title,
  body: "Should we align logical replication slots with streaming failover? Looking for opinions.",
  created_at: base_time + 7.days,
  message_id_suffix: "logical-repl-1"
)

disc_msg2 = create_message(
  topic: discussion_topic,
  sender: bob_alias,
  subject: "Re: #{discussion_topic.title}",
  body: <<~BODY,
    > Should we align logical replication slots with streaming failover? Looking for opinions.

    We need better slot fencing; maybe add a standby-safe flag and WAL distance guard. See [1].

    > Looking for opinions.
    Agreed; let's gate logical slots on replay timeline, too. [2]

    [1]: https://example.com/slot-fencing
    [2]: https://example.com/replay-timeline-guard
  BODY
  created_at: base_time + 7.days + 6.hours,
  reply_to: disc_msg1,
  message_id_suffix: "logical-repl-2"
)

disc_msg3 = create_message(
  topic: discussion_topic,
  sender: carol_alias,
  subject: "Re: #{discussion_topic.title}",
  body: <<~BODY,
    Agreed. Could also emit a new progress metric so monitoring can alert earlier.

    diff --git a/src/backend/replication/slot.c b/src/backend/replication/slot.c
    index 3333333..4444444 100644
    --- a/src/backend/replication/slot.c
    +++ b/src/backend/replication/slot.c
    @@
     ReplicationSlot *
     ReplicationSlotCreate(const char *name, bool db_specific)
     {
    +    if (RecoveryInProgress())
    +        ereport(ERROR,
    +                (errcode(ERRCODE_OBJECT_NOT_IN_PREREQUISITE_STATE),
    +                 errmsg("cannot create logical replication slot during recovery")));
         /* existing logic */
     }
  BODY
  created_at: base_time + 8.days,
  reply_to: disc_msg2,
  message_id_suffix: "logical-repl-3"
)

disc_msg4 = create_message(
  topic: discussion_topic,
  sender: alice_alias,
  subject: "Re: #{discussion_topic.title}",
  body: <<~BODY,
    > We need better slot fencing; maybe add a standby-safe flag and WAL distance guard.
    > Agreed. Could also emit a new progress metric so monitoring can alert earlier.

    Let's prototype slot fencing and see if it breaks cascading setups.

    > emit a new progress metric
    Sure, but let's avoid polling; maybe piggyback on sender heartbeats.
  BODY
  created_at: base_time + 9.days,
  reply_to: disc_msg3,
  message_id_suffix: "logical-repl-4"
)

MessageReadRange.add_range(
  user: dave_user,
  topic: discussion_topic,
  start_id: disc_msg1.id,
  end_id: disc_msg3.id,
  read_at: base_time + 9.days
)

ThreadAwareness.mark_until(
  user: dave_user,
  topic: discussion_topic,
  until_message_id: disc_msg4.id,
  aware_at: base_time + 9.days
)

# 6) Contributor activity only (no core/committer)
contrib_topic = Topic.create!(
  title: "Background worker metrics",
  creator: carol_alias,
  creator_person: carol_alias.person,
  created_at: base_time + 10.days,
  updated_at: base_time + 10.days
)

contrib_messages = []
contrib_messages << create_message(
  topic: contrib_topic,
  sender: carol_alias,
  subject: contrib_topic.title,
  body: "Proposal to expose background worker stats via a new pg_stat_workers view.",
  created_at: base_time + 10.days,
  message_id_suffix: "bgworkers-1"
)

(2..12).each do |i|
  sender = i.odd? ? carol_alias : dave_alias
  contrib_messages << create_message(
    topic: contrib_topic,
    sender: sender,
    subject: "Re: #{contrib_topic.title}",
    body: "Follow-up ##{i} on worker stats (no core/committer replies here).",
    created_at: base_time + 10.days + i.hours,
    reply_to: contrib_messages.last,
    message_id_suffix: "bgworkers-#{i}"
  )
end

# 7) Committer activity without core
committer_topic = Topic.create!(
  title: "Autovacuum freeze thresholds",
  creator: bob_alias,
  creator_person: bob_alias.person,
  created_at: base_time + 11.days,
  updated_at: base_time + 11.days
)

committer_messages = []
committer_messages << create_message(
  topic: committer_topic,
  sender: bob_alias,
  subject: committer_topic.title,
  body: "Considering lowering default freeze_age to reduce wraparound risk.",
  created_at: base_time + 11.days,
  message_id_suffix: "freeze-1"
)

(2..14).each do |i|
  sender = i % 3 == 0 ? dave_alias : bob_alias
  committer_messages << create_message(
    topic: committer_topic,
    sender: sender,
    subject: "Re: #{committer_topic.title}",
    body: "Iteration ##{i} on freeze thresholds without core involvement.",
    created_at: base_time + 11.days + i.hours,
    reply_to: committer_messages.last,
    message_id_suffix: "freeze-#{i}"
  )
end

# 8) Past contributor only
past_topic = Topic.create!(
  title: "Historical patch import",
  creator: legacy_alias,
  creator_person: legacy_alias.person,
  created_at: base_time + 12.days,
  updated_at: base_time + 12.days
)

(1..6).each do |i|
  create_message(
    topic: past_topic,
    sender: legacy_alias,
    subject: past_topic.title,
    body: "Legacy mail ##{i} from a past contributor.",
    created_at: base_time + 12.days + i.hours,
    reply_to: nil,
    message_id_suffix: "legacy-import-#{i}"
  )
end

# 9) Long thread (100+ messages with branching)
long_topic = Topic.create!(
  title: "Streaming replication design meeting",
  creator: bob_alias,
  creator_person: bob_alias.person,
  created_at: base_time + 13.days,
  updated_at: base_time + 13.days
)

long_messages = []
long_messages << create_message(
  topic: long_topic,
  sender: bob_alias,
  subject: long_topic.title,
  body: <<~BODY,
    Kickoff for replication design meeting. Agenda attached in follow-ups.

    Long-form agenda (trimmed):
    - Replication slots: fencing, monitoring, GC
    - Apply workers: concurrency, batching, memory caps
    - WAL sender backpressure: avoid head-of-line blocking
    - DDL replication gaps: schema sync, extension hooks
    - Conflict handling: subscriber-side policies
  BODY
  created_at: base_time + 13.days,
  message_id_suffix: "repl-meeting-1"
)

senders_cycle = [ bob_alias, carol_alias, dave_alias, alice_alias ]
(2..120).each do |i|
  sender = senders_cycle[(i - 2) % senders_cycle.length]
  reply_to = if i % 25 == 0
               long_messages.first
  elsif i % 10 == 0
               long_messages[4] || long_messages.first
  else
               long_messages.last
  end
  long_messages << create_message(
    topic: long_topic,
    sender: sender,
    subject: "Re: #{long_topic.title}",
    body: "Message ##{i} continuing the replication design discussion.",
    created_at: base_time + 13.days + i.minutes,
    reply_to: reply_to,
    message_id_suffix: "repl-meeting-#{i}"
  )
end

# add explicit branching replies to a single message
branch_anchor = long_messages[9] || long_messages.first
3.times do |idx|
  create_message(
    topic: long_topic,
    sender: senders_cycle[idx],
    subject: "Re: #{long_topic.title}",
    body: "Side branch reply ##{idx + 1} to anchor message.",
    created_at: base_time + 13.days + 3.hours + idx.minutes,
    reply_to: branch_anchor,
    message_id_suffix: "repl-branch-#{idx + 1}"
  )
end

# 10) Moderate threads (10-30 messages)
moderate_topic_1 = Topic.create!(
  title: "Connection pool tuning",
  creator: dave_alias,
  creator_person: dave_alias.person,
  created_at: base_time + 14.days,
  updated_at: base_time + 14.days
)

moderate_msgs_1 = []
moderate_msgs_1 << create_message(
  topic: moderate_topic_1,
  sender: dave_alias,
  subject: moderate_topic_1.title,
  body: <<~BODY,
    How far can we push connection pooling defaults before we degrade latency?

    A few detailed notes from last week's testing [1]:
    - Pool size 50: CPU 35%, p95 latency 28ms, 0 errors
    - Pool size 100: CPU 52%, p95 latency 41ms, spikes when autovacuum runs
    - Pool size 200: CPU 78%, p95 latency 77ms, occasional timeouts
    We probably want an adaptive pool that targets utilization instead of a fixed cap.

    [1]: https://example.com/pooling-results
  BODY
  created_at: base_time + 14.days,
  message_id_suffix: "pooling-1"
)

(2..18).each do |i|
  sender = [ bob_alias, carol_alias, dave_alias ][i % 3]
  moderate_msgs_1 << create_message(
    topic: moderate_topic_1,
    sender: sender,
    subject: "Re: #{moderate_topic_1.title}",
    body: <<~BODY,
      > How far can we push connection pooling defaults before we degrade latency?
      Pooling discussion post ##{i}.

      > Pool size 200: CPU 78%, p95 latency 77ms, occasional timeouts
      That aligns with our Grafana charts; we start dropping at ~75% CPU.
    BODY
    created_at: base_time + 14.days + i.hours,
    reply_to: moderate_msgs_1.last,
    message_id_suffix: "pooling-#{i}"
  )
end

moderate_topic_2 = Topic.create!(
  title: "Monitoring extension roadmap",
  creator: carol_alias,
  creator_person: carol_alias.person,
  created_at: base_time + 15.days,
  updated_at: base_time + 15.days
)

moderate_msgs_2 = []
moderate_msgs_2 << create_message(
  topic: moderate_topic_2,
  sender: carol_alias,
  subject: moderate_topic_2.title,
  body: <<~BODY,
    Planning a monitoring extension: metrics inventory, sampling cadence, and storage.

    Longer design sketch:
    - Capture WAL sender lag, apply lag, replay pause reasons
    - Sample IO times from pg_stat_io and expose histograms
    - Store recent samples in shared memory, ship to an external sink periodically
    - Pluggable exporters so folks can emit to Prometheus/OTLP [1]

    [1]: https://example.com/monitoring-design
  BODY
  created_at: base_time + 15.days,
  message_id_suffix: "monitoring-1"
)

(2..12).each do |i|
  sender = i.even? ? dave_alias : carol_alias
  moderate_msgs_2 << create_message(
    topic: moderate_topic_2,
    sender: sender,
    subject: "Re: #{moderate_topic_2.title}",
    body: <<~BODY,
      > Planning a monitoring extension: metrics inventory, sampling cadence, and storage.
      Monitoring post ##{i} expanding on the roadmap.

      > Pluggable exporters so folks can emit to Prometheus/OTLP
      Yes, and maybe a JSON endpoint for quick hacks.
    BODY
    created_at: base_time + 15.days + i.hours,
    reply_to: moderate_msgs_2.last,
    message_id_suffix: "monitoring-#{i}"
  )
end

# Threads to exercise participant display (5+)
five_part_topic = Topic.create!(
  title: "Five participant sampler",
  creator: alice_alias,
  creator_person: alice_alias.person,
  created_at: base_time + 16.days,
  updated_at: base_time + 16.days
)

five_participants = [ alice_alias, bob_alias, carol_alias, dave_alias, legacy_alias ]
five_msgs = []
five_msgs << create_message(
  topic: five_part_topic,
  sender: five_participants[0],
  subject: five_part_topic.title,
  body: "Kickoff for a 5-participant thread.",
  created_at: base_time + 16.days,
  message_id_suffix: "five-part-1"
)

five_participants[1..].each_with_index do |ali, idx|
  five_msgs << create_message(
    topic: five_part_topic,
    sender: ali,
    subject: "Re: #{five_part_topic.title}",
    body: "Reply ##{idx + 2} to show distinct participant #{ali.name}.",
    created_at: base_time + 16.days + (idx + 1).hours,
    reply_to: five_msgs.last,
    message_id_suffix: "five-part-#{idx + 2}"
  )
end

six_part_topic = Topic.create!(
  title: "Six participant sampler",
  creator: bob_alias,
  creator_person: bob_alias.person,
  created_at: base_time + 17.days,
  updated_at: base_time + 17.days
)

six_participants = [ alice_alias, bob_alias, carol_alias, dave_alias, legacy_alias, ci_bot_alias ]
six_msgs = []
six_msgs << create_message(
  topic: six_part_topic,
  sender: six_participants[0],
  subject: six_part_topic.title,
  body: "Kickoff for a 6-participant thread.",
  created_at: base_time + 17.days,
  message_id_suffix: "six-part-1"
)

six_participants[1..].each_with_index do |ali, idx|
  six_msgs << create_message(
    topic: six_part_topic,
    sender: ali,
    subject: "Re: #{six_part_topic.title}",
    body: "Message ##{idx + 2} from #{ali.name} to push participant count over the limit.",
    created_at: base_time + 17.days + (idx + 1).hours,
    reply_to: six_msgs.last,
    message_id_suffix: "six-part-#{idx + 2}"
  )
end

# Extra topics to fill multiple pages with variety
extra_topics = []
(1..50).each do |i|
  creator = [ alice_alias, bob_alias, carol_alias, dave_alias ][i % 4]
  created_at = now - (15.days + i.hours)
  topic = Topic.create!(
    title: "Archive sampler #{i}",
    creator: creator,
    creator_person: creator.person,
    created_at: created_at,
    updated_at: created_at
  )

  msgs = []
  msgs << create_message(
    topic: topic,
    sender: creator,
    subject: topic.title,
    body: "Sampler thread #{i} kickoff with creator #{creator.name}.",
    created_at: created_at,
    message_id_suffix: "sampler-#{i}-1"
  )
  msgs << create_message(
    topic: topic,
    sender: [ alice_alias, bob_alias, carol_alias, dave_alias ][(i + 1) % 4],
    subject: "Re: #{topic.title}",
    body: "Follow-up #{i}a to keep paging realistic.",
    created_at: created_at + 2.hours,
    reply_to: msgs.last,
    message_id_suffix: "sampler-#{i}-2"
  )
  msgs << create_message(
    topic: topic,
    sender: [ alice_alias, bob_alias, carol_alias, dave_alias ][(i + 2) % 4],
    subject: "Re: #{topic.title}",
    body: "Follow-up #{i}b with another participant.",
    created_at: created_at + 4.hours,
    reply_to: msgs.last,
    message_id_suffix: "sampler-#{i}-3"
  )

  # Mix awareness/read states for coverage
  if i % 4 == 0
    mark_read_until(user: alice_user, topic: topic, message: msgs.last, timestamp: created_at + 5.hours)
  elsif i % 3 == 0
    mark_aware_until(user: bob_user, topic: topic, message: msgs.last, timestamp: created_at + 5.hours)
  end

  extra_topics << { topic: topic, messages: msgs }
end

# Threads to exercise all smart_time_display branches
recent_topic = Topic.create!(
  title: "Recent activity thread",
  creator: alice_alias,
  creator_person: alice_alias.person,
  created_at: now - 2.days,
  updated_at: now - 2.days
)

recent_msg1 = create_message(
  topic: recent_topic,
  sender: alice_alias,
  subject: recent_topic.title,
  body: "Thread within 7 days to trigger relative time display.",
  created_at: now - 2.days,
  message_id_suffix: "recent-1"
)

create_message(
  topic: recent_topic,
  sender: bob_alias,
  subject: "Re: #{recent_topic.title}",
  body: "Reply to keep this within the relative window.",
  created_at: now - 1.day,
  reply_to: recent_msg1,
  message_id_suffix: "recent-2"
)

old_topic_time = now - 400.days
old_topic = Topic.create!(
  title: "Previous year discussion",
  creator: carol_alias,
  creator_person: carol_alias.person,
  created_at: old_topic_time,
  updated_at: old_topic_time
)

old_msg1 = create_message(
  topic: old_topic,
  sender: carol_alias,
  subject: old_topic.title,
  body: "Thread from a previous year to trigger absolute year formatting.",
  created_at: old_topic_time,
  message_id_suffix: "old-year-1"
)

create_message(
  topic: old_topic,
  sender: legacy_alias,
  subject: "Re: #{old_topic.title}",
  body: "Follow-up to keep timestamp anchored in the prior year.",
  created_at: old_topic_time + 2.days,
  reply_to: old_msg1,
  message_id_suffix: "old-year-2"
)

# Notes and read/awareness states
alice_notes = NoteBuilder.new(author: alice_user)
bob_notes   = NoteBuilder.new(author: bob_user)
carol_notes = NoteBuilder.new(author: carol_user)

# Patch thread notes (two authors)
alice_notes.create!(
  topic: patch_topic,
  message: msg3,
  body: "- Add WAL position to progress report\n- Split heap vs index counters\n- Autovacuum should emit too\n@ExampleCompany please sync on scope"
)
bob_notes.create!(
  topic: patch_topic,
  message: msg1,
  body: "Queued for next CF round; tracking in CF app.\n@ExampleCompany heads-up for review bandwidth"
)

# RFC thread notes (thread + message, different authors)
carol_notes.create!(
  topic: rfc_topic,
  body: "Thread summary: add index AM hooks, include sample AM + docs.\n@ExampleCompany track follow-ups"
)
alice_notes.create!(
  topic: rfc_topic,
  message: rfc_msg2,
  body: "Docs + sample AM needed before commit. Add SGML + README.\n@ExampleCompany can we help draft?"
)

# Discussion thread: mix of thread/message notes from different people
carol_notes.create!(
  topic: discussion_topic,
  body: "Thread note: align logical slots with failover, add standby-safe flag.\n@ExampleCompany capture design risks"
)
alice_notes.create!(
  topic: discussion_topic,
  message: disc_msg4,
  body: "Message note: prototype slot fencing, watch cascading setups; prefer heartbeat piggyback.\n@ExampleCompany please review"
)

# Committer topic: partially read with a note
bob_notes.create!(
  topic: committer_topic,
  message: committer_messages[3],
  body: "Action: test lower freeze_age under heavy autovacuum.\n@ExampleCompany check lab capacity"
)

# Moderate topic note for visibility
carol_notes.create!(
  topic: moderate_topic_1,
  message: moderate_msgs_1[5],
  body: "Pooling experiments look good; consider adaptive target.\n@ExampleCompany let's benchmark with PG16"
)

# Notes on extra sampler topics for visibility across pages
extra_topics.each_with_index do |entry, idx|
  next unless (idx % 5).zero?
  builder = [ alice_notes, bob_notes, carol_notes ][idx % 3]
  message = entry[:messages][1] || entry[:messages].last
  builder.create!(
    topic: entry[:topic],
    message: message,
    body: "Sampler note ##{idx + 1} on #{entry[:topic].title}.\n@ExampleCompany follow-up #{idx + 1}"
  )
end

timestamp_now = Time.current

# Fully read threads
mark_all_read(user: alice_user, topic: patch_topic, timestamp: timestamp_now)
mark_all_read(user: bob_user, topic: patch_topic, timestamp: timestamp_now)
mark_all_read(user: carol_user, topic: rfc_topic, timestamp: timestamp_now)
mark_all_read(user: alice_user, topic: resolved_topic, timestamp: timestamp_now)
mark_all_read(user: bob_user, topic: committer_topic, timestamp: timestamp_now)

# Partially read threads
mark_read_until(user: carol_user, topic: patch_topic, message: msg2, timestamp: timestamp_now)
mark_read_until(user: bob_user, topic: discussion_topic, message: disc_msg2, timestamp: timestamp_now)
mark_read_until(user: carol_user, topic: discussion_topic, message: disc_msg3, timestamp: timestamp_now)
mark_read_until(user: alice_user, topic: committer_topic, message: committer_messages[5], timestamp: timestamp_now)
mark_read_until(user: carol_user, topic: moderate_topic_1, message: moderate_msgs_1[-4], timestamp: timestamp_now)

# Awareness-only threads
mark_aware_until(user: bob_user, topic: bot_topic, message: bot_topic.messages.last, timestamp: timestamp_now)
mark_aware_until(user: carol_user, topic: bot_topic, message: bot_topic.messages.last, timestamp: timestamp_now)
mark_aware_until(user: alice_user, topic: discussion_topic, message: disc_msg4, timestamp: timestamp_now)
mark_aware_until(user: bob_user, topic: rfc_topic, message: rfc_msg2, timestamp: timestamp_now)
mark_aware_until(user: carol_user, topic: committer_topic, message: committer_messages.last, timestamp: timestamp_now)
mark_aware_until(user: alice_user, topic: long_topic, message: long_messages[20], timestamp: timestamp_now)

# Leave some threads entirely new/unaware (e.g., past_topic, moderate_topic_2, contrib_topic)

# Topic stars and message notifications
puts "Creating topic stars and message notification activities..."

TopicStar.create!(user: alice_user, topic: patch_topic)
TopicStar.create!(user: bob_user, topic: patch_topic)
TopicStar.create!(user: carol_user, topic: patch_topic)

TopicStar.create!(user: alice_user, topic: rfc_topic)
TopicStar.create!(user: carol_user, topic: rfc_topic)

TopicStar.create!(user: bob_user, topic: discussion_topic)
TopicStar.create!(user: carol_user, topic: discussion_topic)
TopicStar.create!(user: dave_user, topic: discussion_topic)

TopicStar.create!(user: alice_user, topic: recent_topic)
TopicStar.create!(user: dave_user, topic: recent_topic)

Activity.create!(
  user: alice_user,
  activity_type: "topic_message_received",
  subject: msg2,
  payload: { topic_id: patch_topic.id, message_id: msg2.id },
  read_at: nil,
  created_at: msg2.created_at,
  updated_at: msg2.created_at
)

Activity.create!(
  user: bob_user,
  activity_type: "topic_message_received",
  subject: msg3,
  payload: { topic_id: patch_topic.id, message_id: msg3.id },
  read_at: timestamp_now,
  created_at: msg3.created_at,
  updated_at: msg3.created_at
)

Activity.create!(
  user: carol_user,
  activity_type: "topic_message_received",
  subject: msg3,
  payload: { topic_id: patch_topic.id, message_id: msg3.id },
  read_at: nil,
  created_at: msg3.created_at,
  updated_at: msg3.created_at
)

Activity.create!(
  user: alice_user,
  activity_type: "topic_message_received",
  subject: rfc_msg2,
  payload: { topic_id: rfc_topic.id, message_id: rfc_msg2.id },
  read_at: timestamp_now,
  created_at: rfc_msg2.created_at,
  updated_at: rfc_msg2.created_at
)

Activity.create!(
  user: carol_user,
  activity_type: "topic_message_received",
  subject: rfc_msg2,
  payload: { topic_id: rfc_topic.id, message_id: rfc_msg2.id },
  read_at: nil,
  created_at: rfc_msg2.created_at,
  updated_at: rfc_msg2.created_at
)

Activity.create!(
  user: bob_user,
  activity_type: "topic_message_received",
  subject: disc_msg3,
  payload: { topic_id: discussion_topic.id, message_id: disc_msg3.id },
  read_at: nil,
  created_at: disc_msg3.created_at,
  updated_at: disc_msg3.created_at
)

Activity.create!(
  user: carol_user,
  activity_type: "topic_message_received",
  subject: disc_msg4,
  payload: { topic_id: discussion_topic.id, message_id: disc_msg4.id },
  read_at: timestamp_now,
  created_at: disc_msg4.created_at,
  updated_at: disc_msg4.created_at
)

Activity.create!(
  user: dave_user,
  activity_type: "topic_message_received",
  subject: disc_msg4,
  payload: { topic_id: discussion_topic.id, message_id: disc_msg4.id },
  read_at: nil,
  created_at: disc_msg4.created_at,
  updated_at: disc_msg4.created_at
)

recent_reply = create_message(
  topic: recent_topic,
  sender: carol_alias,
  subject: "Re: #{recent_topic.title}",
  body: "Fresh reply to demonstrate starred topic notifications.",
  created_at: now - 2.hours,
  reply_to: recent_msg1,
  message_id_suffix: "recent-3"
)

Activity.create!(
  user: alice_user,
  activity_type: "topic_message_received",
  subject: recent_reply,
  payload: { topic_id: recent_topic.id, message_id: recent_reply.id },
  read_at: nil,
  created_at: recent_reply.created_at,
  updated_at: recent_reply.created_at
)

Activity.create!(
  user: dave_user,
  activity_type: "topic_message_received",
  subject: recent_reply,
  payload: { topic_id: recent_topic.id, message_id: recent_reply.id },
  read_at: nil,
  created_at: recent_reply.created_at,
  updated_at: recent_reply.created_at
)

puts "Development seed data loaded."
