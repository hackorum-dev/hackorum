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
  run of this tool, re-judge it; `manual` = given by hand; `overlap` = a
  changed-file overlap guess. The last three are only candidates in every mode.
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

## Task 1: lineage

For every patchset say which earlier patchset it derives from (`parent_message_id`,
null if none) and how:

- `resend`: same content sent again (ping, new commitfest, wrong list)
- `rebase`: same change on a newer base, trivial or minimal conflict resolution
- `minor_revision`: review feedback applied, typos, small bugs, test tweaks, same architecture
- `major_rework`: answers the same need but works differently
- `remainder`: part of the series was committed, the rest is resent (0003 became 0001, etc.)
- `fix_on_top`: a delta against an earlier patchset, not a full version
- `new_series`: a new piece of work in this thread, no earlier patchset is a real parent

The first patchset is `new_series` with a null parent. A later patchset may go
back to any earlier one, not just the previous. Mixed cases: pick the dominant
kind and say so in `reason`. Read the patches before the discussion, the
discussion explains the why, the patches are the what.

<!-- lineage -->
## Task 2: no commits

This thread has no linked commit and is recent enough that a committed version
would carry a Discussion trailer, so there is nothing to judge.
`verdicts` and `extra_commits` must be `[]`. Do not search the checkout for commits.

<!-- /lineage -->
<!-- trailer full -->
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

<!-- trailer -->
Candidates with `origin: trailer` are linked to this thread by their Discussion
trailers; take that as given. For each of them say which patchset it was
committed from and how much it changed. Use `from_discussion` when the commit
came from the thread without an attached patchset. Answer `not_this_thread`
only when the trailer is clearly wrong. Candidates with any other origin are
only candidates: judge them on the evidence, rejecting them is fine. Do not
search the checkout for other commits; `extra_commits` must be `[]`.
<!-- /trailer -->
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
`[]`.
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

When the verdict has no source patchset (`from_discussion`, `not_this_thread`,
`undecided`), judge coverage against the last patchset of the thread.
A Reviewed-by trailer in PostgreSQL means the person spent time on the patch,
not that they approved it. The `reviewer` field must be copied exactly from the
`reviewers` list. `note` is one sentence on what they did. Candidates with no
reviewers: `reviews` is `[]`.

<!-- /trailer full -->
## Task 4: story

A short plain-text summary of how the thread progressed to its commits: which
patchsets led to which commit, which were abandoned, where bugfix rounds
started. Five to fifteen lines, with reference tokens for every message and
commit mentioned (see Rules).

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
  index.json, never the NNN ordinal. `author_message_id` may be any message of
  the thread, by the id in its header.
- Whenever you refer to a message write `[msg:<message_id>]`, and to a commit
  `[commit:<full sha>]`; the UI turns these into links. Never write bare message
  numbers or shas in reason, evidence, note or story, and cite a patchset by
  its `[msg:<message_id>]`, not by its attachment file name. Source paths such
  as src/backend/foo.c are fine and wanted in evidence.
- A patchset with `parse_error` has no metrics; still give it a lineage entry,
  judged from the message text, with low confidence if needed.
- A candidate with `diff_available: false` has no commits/<sha> dir; look the sha
  up in the checkout, and if it is not there answer `undecided`.
- `previous` is the last run's answer: re-derive, do not copy; if you disagree
  with it, say so in reason or evidence.
- When a commit draws on several patchsets, `source_message_id` is the latest
  patchset it matches.
- `extra_commits` must be present, as an empty array when there is nothing to add.
- `confidence` is 0 to 1. Be honest, not polite.
- `reason` and `evidence` are one or two sentences each, concrete (source paths,
  hunk counts, dates, reference tokens), no padding.
- Threads above 150 messages: split the message reading across subagents by
  message range, keep the lineage decision yourself.
- The final answer must be only the JSON object described by the output schema,
  with one `lineage` entry per patchset, one `verdicts` entry per candidate
  (none when there are no candidates), and `extra_commits` for commits you
  verified yourself.
