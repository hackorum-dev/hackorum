# Patchset lineage for thread {{topic_id}}: {{title}} (run {{run_id}}, mode {{mode}})

You are looking at one pgsql mailing list thread with {{message_count}} messages and
{{patchset_count}} patch submissions, plus {{candidate_count}} candidate commits.
Everything is in this directory. Read `index.json` first.

## What is here

- `index.json`: the patchset table (ordinal = the message number in the thread,
  message id, date, sender, files, apply status on the postgres checkout), the
  candidate commits, and the previous run's answer if there was one.
- A patchset entry with `nocfbot: true` is an attachment the author marked to
  keep CI away from it; these are usually deltas on top of an earlier patchset
  (`fix_on_top`) rather than full versions.
- A candidate is the canonical commit of a change, the one that landed on the
  development branch. Its `backports` list holds the shas of the same change
  cherry-picked into stable branches; they are not separate candidates and have
  no commits/<sha> dir. `reviewers` lists the names credited as reviewers on the
  commit and its backports.
- A candidate's `origin` says how it got on the list: `trailer` = its
  Discussion trailer links it to this thread; `previous` = linked by an earlier
  run of this tool, re-judge it (update runs have none); `manual` = given by
  hand; `overlap` = a changed-file overlap guess. The last three are only
  candidates in every mode.
- `pairs.json` and `commit_scores.json`: mechanical similarity numbers for every
  (later, earlier) patchset pair and for every commit against every patchset.
  Grep them by `later_message_id` / `sha` rather than reading whole.
- `messages/NNN.txt`: every message of the thread in order, quotes stripped.
  A `Patchset: patchsets/NNN` line marks where a patchset was attached.
- `patchsets/NNN/`: the raw patch files of that submission.
- `commits/<sha>/message.txt` and `diff.patch`: each candidate commit.
- The postgres git checkout is mounted read-only at `{{repo_path}}`. Use git
  (log, show, diff, blame, apply --check) there whenever the numbers are
  ambiguous. You cannot write to it and you have no network.

<!-- update -->
## This is an update run

An earlier run already answered for this thread up to message
`since_message_id`; its answer is `previous` in index.json and it stands. Do
not re-judge it and do not repeat it. Your answer covers only what is new:

- `lineage`: one entry per patchset with `new: true`, none for the others. A
  new patchset's parent may be any patchset, old or new.
- `verdicts`: one per candidate; every candidate is a commit `previous` has no
  verdict for. Tasks 2, 3 and 3b apply to them as written; a new commit may
  come from an old patchset.
- `story`: the whole updated story, not only the new part. Keep the entries of
  `previous.story` unless the new messages show one is wrong, rewrite the
  entries on where the thread stands, and add the new steps.

Read the messages listed in `new_message_ordinals` in full. Read older
messages only to look something up: the review rounds behind a new commit, a
parent patchset, who someone is.

<!-- /update -->
<!-- discussion -->
## This thread has no patchsets

Nobody attached a patch here: the thread is a bug report, a question, a
discussion after a commit on pgsql-committers, or a fix posted inline in a
message body. Inline diffs are not patchsets. `lineage` is `[]`, and
`pairs.json` and `commit_scores.json` have nothing to compare. Rarely
index.json still lists a few patchsets, attachments marked `nocfbot`; then give
each one a `lineage` entry: `parent_message_id` an earlier patchset or null,
`step_kind` `fix_on_top` for a delta and `new_series` otherwise.

The candidates still came out of this discussion. In Task 2 the verdict is
normally `from_discussion`, with `source_message_id` null:

- a fix posted inline: cite that message in `evidence`, and name its sender in
  `author_name` / `author_message_id` when that is not the committer
- a bug report: the reporter is not the author; when the committer wrote the
  fix, `author_name` and `author_message_id` are null
- a follow-up to an earlier commit (a buildfarm failure, a review after the
  push): say which commit it follows up in `evidence`

In Tasks 3 and 3b, judge coverage against the inline fix or the approach
agreed in the thread; `reviewed_message_ids` is `[]`. Keep the story short.

<!-- /discussion -->
<!-- trailer full lineage update -->
## Task 1: lineage

<!-- trailer full lineage -->
For every patchset say which earlier patchset it derives from (`parent_message_id`,
null if none) and how:
<!-- /trailer full lineage -->
<!-- update -->
For every patchset with `new: true` say which earlier patchset it derives from
(`parent_message_id`, null if none) and how:
<!-- /update -->

- `resend`: same content sent again (ping, new commitfest, wrong list)
- `rebase`: same change on a newer base, trivial or minimal conflict resolution
- `minor_revision`: review feedback applied, typos, small bugs, test tweaks, same architecture
- `major_rework`: answers the same need but works differently
- `remainder`: part of the series was committed, the rest is resent (0003 became 0001, etc.)
- `fix_on_top`: a delta against an earlier patchset, not a full version
- `new_series`: a new piece of work in this thread, no earlier patchset is a real parent

<!-- trailer full lineage -->
The first patchset is `new_series` with a null parent.
<!-- /trailer full lineage -->
A later patchset may go back to any earlier one, not just the previous. Mixed
cases: pick the dominant kind and say so in `reason`. Read the patches before the discussion, the
discussion explains the why, the patches are the what.
<!-- /trailer full lineage update -->

<!-- lineage -->
## Task 2: no commits

This thread has no linked commit and is recent enough that a committed version
would carry a Discussion trailer, so there is nothing to judge.
`verdicts` and `extra_commits` must be `[]`. Do not search the checkout for commits.

<!-- /lineage -->
<!-- trailer full discussion update -->
## Task 2: commit verdicts

One commit per change: judge the canonical commit, never report its backports
separately. Verdicts:

- `as_is`: the commit is one of the patchsets (modulo rebase and whitespace)
- `modified`: the commit is a patchset with committer edits
- `partial`: the commit is a subset of a patchset or series
- `from_discussion`: the commit was made from this thread's discussion without a
  matching attached patchset (an inline patch in a message, an agreed one-liner,
  a revert decided here)
- `not_this_thread`: the commit does not come from any patchset here
- `undecided`: you cannot tell with the material available

`source_message_id` names the patchset it came from, null for `from_discussion`,
`not_this_thread` and `undecided`.

`author_name` and `author_message_id`: who wrote the committed patch, when it
is not the person who sent the patchset message (a committer or reviewer
forwarding someone else's work, a patch credited in its own header or in the
discussion). Give the name as it appears in the thread and the id of a message
that person sent in this thread (the `id` in the `Message:` line, not the `#N`
ordinal), so we can identify them; both null when the sender is the author or
you cannot tell.

`change_level` says how much the committed version differs from that patchset.
Set it for `modified` and `partial`, null for every other verdict:

- `light`: formatting, naming, comments, commit message, test tweaks or removal
- `moderate`: local logic changes, a function reworked, a case added
- `significant`: the approach or structure changed

<!-- trailer discussion update -->
Candidates with `origin: trailer` are linked to this thread by their Discussion
trailers; take that as given. For each of them say which patchset it was
committed from and how much it changed. Use `from_discussion` when the commit
came from the thread without an attached patchset. Answer `not_this_thread`
only when the trailer is clearly wrong. Candidates with any other origin are
only candidates: judge them on the evidence, rejecting them is fine. Do not
search the checkout for other commits; `extra_commits` must be `[]`.
<!-- /trailer discussion update -->
<!-- full -->
There may be no candidates at all; for most threads of this age the job is
Task 2b. Candidates, when present, are only candidates (found by hand or by
overlap, wrong at times). Rejecting all of them, concluding
that the thread was committed as some other commit you found in git, or saying
you do not have enough confidence, are all correct answers when they are true.
Do not invent a link to satisfy the list. If you find the real commit in git,
report it under Task 2b.

## Task 2b: commits you found

Finding the real commit in the checkout is part of the job, not optional. When
a patchset or this discussion was committed as a commit that is not in the
candidate list, look it up in the git checkout (git log on the touched files
around the right dates, git patch-id, git show) and report it in
`extra_commits` with the same fields as a verdict, `change_level` included.
Report only the master commit of a change, not its stable branch cherry-picks.
Use `extra_commits` only for commits you verified in the checkout; it has no
`not_this_thread` or `undecided`, so a commit you are not sure about goes to
`story` instead. Never put a candidate sha or a backport sha in
`extra_commits`. A found commit has no `reviewers` list, so its `reviews` is
`[]` and the reviewers you find go to `suggested_reviews` (Task 3b).
<!-- /full -->

## Task 3: review coverage

For every candidate with a non-empty `reviewers` list, assess each listed
reviewer from the discussion: which patchsets they reviewed
(`reviewed_message_ids`: the `message_id`s of the patchset entries they looked
at, never the id of their own reply; `[]` when coverage is `none`), and
`coverage`:

- `final`: they reviewed the committed patchset, or an earlier one that was
  followed only by light changes
- `earlier`: they reviewed an earlier version and moderate or significant
  changes followed
- `none`: you find no review activity by them in this thread; "none" is a valid
  answer, do not invent reviews

<!-- trailer full update -->
When the verdict has no source patchset (`from_discussion`, `not_this_thread`,
`undecided`), judge coverage against the last patchset of the thread.
<!-- /trailer full update -->
A Reviewed-by trailer in PostgreSQL means the person spent time on the patch,
not that they approved it. A reviewer who is also the candidate's `committer`
is always `final`: committing the patch means reviewing the committed version,
whether or not the thread shows it. Still list the patchsets they reviewed and
say in `note` what they did in the thread, if anything. The `reviewer` field
must be copied exactly from the `reviewers` list. `note` is one sentence on what they did. Candidates with no
reviewers: `reviews` is `[]`.

## Task 3b: reviewers you found

A commit with an empty `reviewers` list has no Reviewed-by trailer, so name its
reviewers yourself in `suggested_reviews`: for every candidate with an empty
`reviewers` list and a verdict of `as_is`, `modified`, `partial` or
`from_discussion`, and for every entry of `extra_commits`. The bar is the one
committers use for Reviewed-by. A person counts when, in a message dated before
the commit (`committed_at` in index.json, or the committer date in git for
commits you found), they reported a problem in the patch, tested it and reported
the result, said it looked good, or proposed a change the author took. A person
the commit message itself credits as a reviewer counts too, even without a
message in this thread; for one with no review in this thread `coverage` is
`final`, `reviewed_message_ids` is `[]`, and `note` says where the credit comes
from. A person does not count for pings, "needs rebase", cfbot or commitfest
status notes, or anything written after the commit date; the patch's authors
(the sender of the source patchset, `author_name`, any co-author) and the
committer are never reviewers of their own commit. Each commit gets its own
list: in a thread with several commits, reviewing a different patch series or
sub-feature is not reviewing this commit, while reviewing an earlier version of
the same patch is (`earlier`).

One entry per person per commit. `reviewer` is the name as it appears in the
thread, or in the commit message. `reviewer_message_id` is the id of a message
that person sent in this thread, preferably the review itself (the `id` in the
`Message:` line, not the `#N` ordinal); it is how we identify them, so null only
when they never posted in this thread. `reviewed_message_ids` and `coverage`
follow the Task 3 definitions, with `final` and `earlier` the only values, and
`reviewed_message_ids` is `[]` when the commit came from an inline patch with no
patchset entry. A person with no review activity is not listed. `confidence` is
per entry. `note` is one sentence on what they did, with reference tokens.

`suggested_reviews` is `[]` for candidates with a non-empty `reviewers` list and
for verdicts of `not_this_thread` or `undecided`.

<!-- /trailer full discussion update -->
## Task 4: story

An array of plain-text strings telling how the thread got to its commits,
written for a reader who will not open the thread. One step per entry, in
thread order, each a complete sentence that stands on its own; the UI shows
them as list items. Reference tokens for every message and commit mentioned
(see Rules).

Cover the whole thread, not just its ending:

- how it started: who proposed what, and the design decisions settled in
  discussion before or between patchsets (who argued for what, what was
  chosen), since a reader needs those as much as the patch history
- every turn of the design: a review that changed the approach, a long gap
  followed by a rebase, a change of author, reviewers supplying fix-up
  patches that got folded in, a split into or merge of series
- every candidate you judged as coming from this thread: which patchset it
  came from and what changed on the way; commits that landed together from
  the same patchset may share a line, but name each sha
- reverts and why, and the rework that led to a second landing
- bugfix rounds after a commit: the report that started them and what fixed
  them
- what was abandoned or left out, and the stated reason if there is one
- where the thread stands at its last message: all landed, part of the series
  landed and which patches are still in review, stalled, withdrawn; and the
  questions still open if work continues

Length follows the thread. A thread with a few patchsets and one commit needs
five lines; a thread with dozens of patchsets, a revert and a second landing
may need thirty or more entries. Do not drop a phase or merge distinct commits into
"several fixes followed" to keep it short. Do not walk through versions one
by one either: a run of versions that only answered review comments is one
entry, described by what changed across it. Skip pings, plain resends and
rebases that changed nothing, unless they mark the start of a new phase.

## Metrics

- file_jaccard: shared changed files / all changed files
- added_jaccard, removed_jaccard: shared added / removed lines, whitespace-normalized
- changed_jaccard: the same over added and removed lines together
- size_ratio: later lines / earlier lines; for commits: commit / patchset
- areas: code / test / docs / other
- series.shared_subjects: patch subjects both sides have; subject_shift: position
  change of the first shared patch subject
- branch: apply status on the checkout: status applied / failed / infra_failed /
  not_attempted / error, plus base_sha, on_master, base_source and failure_stage
  when known

## Rules

- Every `message_id`, `parent_message_id`, `source_message_id` and entry of
  `reviewed_message_ids` in your answer is the `message_id` field from
  index.json, never the NNN ordinal. `author_message_id` and
  `reviewer_message_id` may be any message of the thread, by the id in its
  header.
- Whenever you refer to a message write `[msg:<message_id>]`, and to a commit
  `[commit:<full sha>]`; the UI turns these into links. Never write bare message
  numbers or shas in reason, evidence, note or story, and cite a patchset by
  its `[msg:<message_id>]`, not by its attachment file name. Source paths such
  as src/backend/foo.c are fine and wanted in evidence.
<!-- trailer full lineage discussion -->
- A patchset with `parse_error` has no metrics; still give it a lineage entry,
  judged from the message text, with low confidence if needed.
<!-- /trailer full lineage discussion -->
<!-- update -->
- A new patchset with `parse_error` has no metrics; still give it a lineage
  entry, judged from the message text, with low confidence if needed.
<!-- /update -->
- A candidate with `diff_available: false` has no commits/<sha> dir; look the sha
  up in the checkout, and if it is not there answer `undecided`.
<!-- trailer full lineage discussion -->
- `previous` is the last run's answer: re-derive, do not copy; if you disagree
  with it, say so in reason or evidence.
<!-- /trailer full lineage discussion -->
- When a commit draws on several patchsets, `source_message_id` is the latest
  patchset it matches.
- `extra_commits` must be present, as an empty array when there is nothing to add.
- `confidence` is 0 to 1. Be honest, not polite.
- `reason` and `evidence` are one or two sentences each, concrete (source paths,
  hunk counts, dates, reference tokens), no padding.
- Threads above 150 messages: split the message reading across subagents by
  message range, keep the lineage decision yourself.
- The final answer must be only the JSON object described by the output schema,
  with one `lineage` entry per patchset (per new patchset in an update run), one `verdicts` entry per candidate
  (none when there are no candidates), and `extra_commits` for commits you
  verified yourself.
