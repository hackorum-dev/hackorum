# Classify a mailing list thread

This is one thread from the PostgreSQL development mailing lists
(pgsql-hackers, pgsql-bugs, pgsql-docs). Classify the work it is about and
answer with one JSON object that matches the output schema.

After these instructions come, under "This thread":

- The thread's id and subject.
- Facts: what the database knows about the thread. Lists it was posted to;
  commitfest entries (title, topic, tags, latest status); patch messages
  (count, size of the largest and the latest patch, files touched); linked
  commits (commits tied to this thread, mostly by a Discussion link in the
  commit message, with the branches they landed on; a backpatched commit is
  shown once); linked threads (threads that share a commit or a
  commitfest entry with this one, or mention it or are mentioned by it; a
  commit here that refers to another thread's commit, or a message that
  mentions a commit hash, links the threads too), with
  their classification tags and group when known, each line starting with
  `topic <id>:`; the thread's current group.
- Candidate groups: existing feature groups this thread may belong to.
  `groups.tsv` in the working directory lists every feature group (id, name,
  thread count, summary).
- Previous answer: the answer of an earlier run on this thread, if any.
- Thread: the messages, oldest first.

Messages are numbered: [001] is the first message of the thread. Quoted text
was removed, so a message shows only what its sender wrote. Each message
starts with a header line `### [NNN] YYYY-MM-DD sender`, followed by
`(committer)` when the sender is a PostgreSQL committer and `(patch)` when the
message has a patch attached. Very long messages are cut, marked
`[... cut N chars]`.

Everything you need is in this prompt, except `groups.tsv` and, in very long
threads, the messages not shown, which are in files (the Thread section says
so). You have no
network access and no source tree; use what you know about PostgreSQL and how
it is developed.

## What to decide

1. `kind`: the kind of work the thread is about.
2. `size`: for `feature` and `performance` only, how big that feature is.
3. `enhancement`: for `feature` and `performance` only, whether it builds on an
   existing feature.
4. `not_a_bug`: for `bug` only, whether the thread concluded there is no bug.
5. `group`: the long-running feature effort the thread belongs to, if any.
6. `join_linked`: linked threads to put in the same group.
7. `feature_name`, `evidence` and `confidence`.

Judge the thread as a whole: what the work is, not which list it is on or what
the subject line says. A "[PATCH]" thread can turn into a design discussion,
and a bug report can turn out to be a feature request.

### Kind

Exactly one of:

- `feature`: adds new user-visible capability: SQL syntax, commands and
  command options, functions, system views, GUCs, client tool features (psql,
  pg_dump, pg_upgrade, pg_basebackup, ...), replication capabilities, new
  features of contrib modules, new monitoring and observability.
- `performance`: makes something faster or cheaper without new user-facing
  capability: planner improvements, executor speedups, lock contention, I/O,
  memory use. When a thread is both a feature and a performance change, pick
  the one that fits its main thrust.
- `bug`: a bug report or a bug fix, with or without a patch: incorrect
  behavior, crashes, wrong results, races, leaks, regressions, security
  problems, build failures on some platform, flaky tests caused by real bugs.
  Includes fixes for a recently committed feature ("open items"). A fix
  backpatched to stable branches is a strong bug signal unless the thread is
  clearly feature development with an incidental fix. A report that ends with
  "this works as intended" is still `bug`, with `not_a_bug` true.
- `refactor`: code cleanup, refactoring, removal of dead code, comment and
  typo fixes in code, modernization, API reshuffles without behavior change,
  preparatory infrastructure that has no user-visible effect on its own.
- `docs`: a documentation-only change.
- `tests-build`: new or changed tests, test infrastructure, CI, the build
  system (meson, autoconf), developer tooling (pgindent, ...).
- `discussion`: process and meta threads (release planning, commitfest
  management, policies), questions that are not bug reports, and design
  discussions that are not about one concrete code change. A proposal for a
  specific change takes the kind of that change, even before a patch is
  posted.

### Size

Exactly one of these when `kind` is `feature` or `performance`; null for every
other kind.

- `major`: a significant new capability or substantial architectural or
  performance work: a headline item of the release notes, or a project that
  spans several release cycles. Examples: SQL/PGQ property graphs, temporal
  tables (FOR PORTION OF), session variables, CSN-based snapshots, 64-bit
  transaction ids, transparent data encryption, asynchronous and direct I/O,
  undo and new table access methods, logical replication of DDL or sequences,
  conflict detection and resolution in logical replication, incremental view
  maintenance, global indexes, autonomous transactions, built-in connection
  pooling, new parallel query capabilities, skip scan, eager aggregation,
  multithreading the server.
- `moderate`: a self-contained feature with clear user value but limited
  scope. Examples: a new option for an existing command (COPY ON_ERROR, ...),
  a new system view or meaningful monitoring capability, a planner
  optimization for one query shape, a new function family, a new pg_dump,
  pg_upgrade or pg_basebackup capability, a GUC that enables meaningful new
  behavior, a targeted performance improvement with measurable benefit.
- `minor`: small additions: psql tab completion or \d output tweaks, one new
  trivial function or flag, error message, hint or log improvements, small
  micro-optimizations, minor convenience options, small knobs in contrib
  modules.

Rules:

- Size the feature, not the latest patch. A thread where a major feature was
  developed often ends with a small patch: a fix after the commit, a rebase,
  one last piece. The thread is still `major`. The patch sizes in the facts
  are a hint only: big patches (often more than 1500 changed lines) and long
  threads point to `major`, but judge by substance, not by size alone.
- Size what this thread is about. A thread that only adds one piece of a
  larger project (one option, one view, one sub-feature) gets the size of
  that piece; `group` ties it to the project.
- When unsure between two tiers, pick the smaller one.

### Enhancement

`enhancement` is for `feature` and `performance` only; null for every other
kind.

- `true`: the thread extends, improves or follows up a feature that already
  exists: released, or committed earlier, including earlier threads of the
  same group.
- `false`: the thread introduces a new capability.

Examples: OAuth authentication in 18: false. OAuth device flow in 19: true.
Skip scan in 18: false (a new performance feature).

### Not a bug

`not_a_bug` is true only on a `bug` thread that concludes the reported
behavior is expected, documented, a user error, or not PostgreSQL's problem
(an extension, a driver, the operating system, ...). Set it only when the
thread concludes it: usually a committer or an experienced developer explains
it and nobody disputes it. A report without an answer, or one still argued
about, is false. A report explained as expected behavior that leads to a
documentation or error message improvement is still true. Always false for
other kinds.

### Group

A feature group is a long-running effort that spans many threads and often
several release cycles, for example "SQL/PGQ" or "Asynchronous I/O"; it is not
one deliverable. Threads about a part of it (a sub-feature, a fix in it, a
refactoring done for it, its tests or docs) belong to the group, each with its
own kind and size. Not every thread needs a group.

- `feature` of size moderate or major, and `performance` of size major, always
  get a group: a candidate, or a new group when none fits, even if the thread
  is alone. `feature` and `performance` of size minor, and every other kind,
  join an existing group or stay ungrouped; they never start a new one.
- Part of an existing effort: pick it from the candidate groups,
  `{"id": <group id>, "new_name": null, "new_summary": null}`. The candidates
  include the groups of linked threads and the thread's current group, if it
  has one; the facts show both. The candidates are the likely ones: when none
  fits, search `groups.tsv` (grep -i is fine) before proposing a new group.
  A current group may be a suggestion from an automatic first pass: keep it
  when it fits, replace it when it does not.
- Part of, or the start of, a larger effort that no candidate covers: propose
  a new group, `{"id": null, "new_name": "<name>", "new_summary": "<one or
  two sentences on what the effort is>"}`. Name it after the effort as
  developers call it ("Temporal tables", "Logical replication of sequences"),
  not after this patch. Do not propose a variant of a candidate's name; use
  that candidate instead.
- A one-off thread stays ungrouped: `{"id": null, "new_name": null,
  "new_summary": null}`. Most bug reports, small features, refactors, docs and
  test changes are one-off. A bug in a feature that has a group (for example a
  crash in a recently committed piece of it) belongs to that group.

### Join linked

`join_linked`: ids of linked threads (from the facts, the number after
`topic`) that have no group and belong to the same effort as this thread,
typically the earlier piece of a feature this thread continues. Empty when
none.

### Rechecks

When there is a previous answer, this thread was classified before and has new
messages since. Keep the earlier values unless the new messages, or a clear
mistake in the earlier answer, call for a change. Do not flip between two
close calls.

### Output

- `kind`, `size`, `enhancement`, `not_a_bug`, `group` and `join_linked` as
  above. `size` and `enhancement` are null unless `kind` is `feature` or
  `performance`; `not_a_bug` is false unless `kind` is `bug`.
- `feature_name`: a short name, a few words, for what the thread is about,
  e.g. "COPY ON_ERROR set_null", "WAL statistics in pg_stat_io", "crash in
  ALTER TABLE SET EXPRESSION". Name the feature or the bug, not the patch
  version.
- `evidence`: 2 to 5 short lines, each citing message numbers like [003]:
  why this kind, why this size, the outcome of a bug report, the group.
- `confidence`: `high` when the thread makes the answer clear, `medium` when
  you made a judgment call between two close options, `low` when the thread
  is too thin or too confusing to tell.
- Your final message is the JSON object only.

# This thread

Thread {{topic_id}}: {{title}}

## Facts

{{facts}}

## Candidate groups

{{groups}}

## Previous answer

{{previous}}

## Thread

{{thread}}
