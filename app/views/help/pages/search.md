# Advanced Search Guide

Hackorum's search supports powerful query syntax that lets you find exactly what you're looking for in the PostgreSQL Hackers mailing list archive. This guide covers all available search operators and shows you how to combine them for precise results.

## Quick Start

The simplest search is just typing keywords:

```
vacuum performance
```

This finds topics containing both "vacuum" AND "performance" in the title or message body.

For phrases, use quotes:

```
"query planning"
```

## Search Selectors

Selectors let you search specific fields. The format is `selector:value`.

### Content Selectors

| Selector | Description | Example |
|----------|-------------|---------|
| `title:` | Search in topic titles only | `title:vacuum` |
| `body:` | Search in message bodies only | `body:"shared buffers"` |

Without a selector, plain text searches both title and body.

### Author Selectors

| Selector | Description | Example |
|----------|-------------|---------|
| `from:` | Topics with messages from author | `from:andres` |
| `starter:` | Topics started by author | `starter:heikki` |
| `last_from:` | Topics where author sent last message | `last_from:robert` |

#### Special Author Values

- **`me`** - Your own messages (requires sign-in)
- **Team names** - Messages from any team member (e.g., `from:core-reviewers`)
- **Contributor types** - Messages from PostgreSQL contributors:
  - `contributor` - Any contributor
  - `committer` - PostgreSQL committers
  - `core_team` - Core team members
  - `major_contributor` - Major contributors
  - `significant_contributor` - Significant contributors

```
from:me                    # Your messages
from:committer             # Messages from any committer
starter:core_team          # Topics started by core team members
```

#### Email vs Name Search

If your search value contains `@`, it searches email addresses only:

```
from:peter@example.org     # Partial email match (finds any email containing this)
from:peter                 # Searches both name and email (partial match)
```

Use quotes for exact matches:

```
from:"peter@example.org"   # Exact email match
from:"Peter Eisentraut"    # Exact name match
```

### Date Selectors

| Selector | Description | Example |
|----------|-------------|---------|
| `first_after:` | Topics created after date | `first_after:2024-01-01` |
| `first_before:` | Topics created before date | `first_before:2023` |
| `messages_after:` | Topics with messages after date | `messages_after:1w` |
| `messages_before:` | Topics with messages before date | `messages_before:2024-06` |
| `last_after:` | Topics with last activity after date | `last_after:today` |
| `last_before:` | Topics with last activity before date | `last_before:yesterday` |

#### Date Formats

**Absolute dates:**
- Full date: `2024-01-15`
- Month: `2024-01` (first day of month)
- Year: `2024` (January 1st)
- ISO timestamp: `2024-01-15T10:30:00`

**Relative dates:**
- `today` - Today
- `yesterday` - Yesterday
- `7d` - 7 days ago
- `2w` - 2 weeks ago
- `3m` - 3 months ago (approximately 90 days)
- `1y` - 1 year ago (approximately 365 days)

```
first_after:2024           # Topics started in 2024 or later
last_after:1w              # Topics with activity in the last week
messages_before:yesterday  # Messages sent before yesterday
```

### Commitfest Selectors

Search for topics by commitfest.


| Selector | Description | Example |
|----------|-------------|---------|
| `commitfest:name` | Topics from commitfest with this name | `commitfest:PG19-Final` |
| `commitfest:[name:name]` | Topics from commitfest with this name | `commitfest:[name:PG19-Drafts]` |
| `commitfest:[status:status]` | Topics from commitfest with this status | `commitfest:[status:committed]` |
| `commitfest:[tag:tag]` | Topics from commitfest with this tag | `commitfest:[tag:bugfix]` |


### Count Selectors

| Selector | Description | Example |
|----------|-------------|---------|
| `messages:` | Filter by message count | `messages:>10` |
| `participants:` | Filter by participant count | `participants:>=5` |
| `contributors:` | Filter by contributor count | `contributors:>0` |

#### Count Operators

- `messages:10` - Exactly 10 messages
- `messages:>10` - More than 10 messages
- `messages:<10` - Fewer than 10 messages
- `messages:>=10` - 10 or more messages
- `messages:<=10` - 10 or fewer messages

```
messages:>50 participants:>10    # Large, active discussions
messages:1 has:patch             # Single-message patch submissions
```

### Presence Selectors

The `has:` selector checks for the presence of specific attributes:

| Value | Description |
|-------|-------------|
| `has:attachment` | Topics with any attachments |
| `has:patch` | Topics with patch attachments (`.patch`, `.diff`, `.diffs`, optionally `.gz`/`.bz2`/`.txt`; ignoring `nocfbot`) |
| `has:commit` | Topics linked to a commit, see [Commits](#commit-selectors) |
| `has:later_fix` | Topics whose commit a later commit message names, see [Fix links](#fix-links) |
| `has:fixes` | Topics whose commit message names an earlier thread's commit, see [Fix links](#fix-links) |
| `has:group` | Topics that belong to a feature group, see [Feature groups](#feature-groups) |
| `has:contributor` | Topics with PostgreSQL contributor activity |
| `has:committer` | Topics with committer activity |
| `has:core_team` | Topics with core team activity |
| `has:commitfest` | Topics linked to a commitfest entry |

```
has:patch first_after:1m         # Recent topics with patches
has:contributor messages:>5      # Active discussions with contributor input
```

### Mailing Lists

`list:` matches the display name of a mailing list, case-insensitively. A thread that was posted to several lists matches each of them.

```
list:hackers                     # Threads on pgsql-hackers
list:bugs has:patch              # Bug list threads with a patch
-list:docs                       # Leave the docs list out
```

### Hidden Lists

Some mailing lists (e.g. `committers`) are hidden by default: their threads are not in the default topic list, but search still finds them.

| Selector | Description |
|----------|-------------|
| `hidden:true` | Also include threads that are only on hidden lists (default) |
| `hidden:false` | Leave them out |

`hidden:` applies to the whole query, so use it at the top level, not inside `OR` or a negated group.

### Personal State Selectors

These require being signed in and filter based on your reading state:

| Selector | Description |
|----------|-------------|
| `unread:me` | Topics with unread messages |
| `read:me` | Topics you've fully read |
| `reading:me` | Topics you've partially read |
| `new:me` | Topics you've never seen |
| `starred:me` | Topics you've starred |
| `notes:me` | Topics where you've added notes |
| `ignored:me` | Topics you've ignored (they are hidden from results unless the query uses `ignored:`) |

#### Team State Selectors

Replace `me` with a team name to filter by team state (you must be a team member):

```
unread:core-reviewers      # Topics unread by anyone on the team
starred:review-team        # Topics starred by any team member
```

### Tag Selectors

Search for topics by tags added to notes. Tags are private to the note author and mentioned users/teams, except global tags: a note that mentions `@global` is visible to everyone, including visitors who are not signed in. Global tags are defined by admins and listed in the sidebar; any signed-in user can add them with a note like `@global #needs-review`.

| Selector | Description | Example |
|----------|-------------|---------|
| `tag:tagname` | Topics with this tag (from any accessible note) | `tag:needs-review` |
| `tag:tagname[from:me]` | Topics with this tag from your own notes | `tag:important[from:me]` |
| `tag:tagname[from:team]` | Topics with this tag from team member notes | `tag:follow-up[from:reviewers]` |
| `tag:[from:me]` | Topics with any tag from your notes | `tag:[from:me]` |
| `tag:[from:team]` | Topics with any tag from team's notes | `tag:[from:reviewers]` |

Use the `[from:]` condition to filter by who created the tag:
- `from:me` - Your own tags
- `from:teamname` - Tags from any team member (you must be a team member)
- `from:username` - Tags from a specific user

```
tag:blocked                       # Topics tagged "blocked" by anyone you can see
tag:review-needed[from:me]        # Topics I tagged "review-needed"
tag:priority[from:core_team]      # Topics tagged "priority" by core_team members
tag:[from:me]                     # Any topics I've tagged
-tag:done                         # Exclude topics tagged "done"
tag:important[from:me] unread:me  # My important tags that are unread
```

### Classification Tags

Besides the notes-based tags, an LLM classifies threads and the bot user `hackorum-bot` writes the result as global tags, so `tag:` finds them and anyone (also visitors) can use them.

| Kind | Tags |
|------|------|
| What the thread is about | `feature`, `performance`, `bug`, `refactor`, `docs`, `tests-build`, `discussion` |
| Size, for features and performance work | `major`, `moderate`, `minor` |
| Extra | `enhancement` (a feature or performance thread that extends something that already exists), `not-a-bug` (a `bug` thread that concluded there is no bug) |

```
tag:bug -tag:not-a-bug -has:commit   # Bug reports with no commit linked
tag:feature tag:major                # Big features
tag:performance has:patch[waiting:any]  # Performance patches nobody reacted to
```

Only threads on pgsql-hackers, pgsql-bugs and pgsql-docs have these tags, and only the ones with activity since the REL_16_BETA1 release (May 2023). Older threads and other lists have no classification, so a search for `-tag:bug` includes them. The classification is a model's guess, expect mistakes.

### Feature Groups

Long-running feature efforts are collected into feature groups, the classification assigns threads to them.

| Selector | Description | Example |
|----------|-------------|---------|
| `group:name` | Topics in this group, by slug or by name | `group:oauth-authentication` |
| `group:"name"` | Same, by name | `group:"OAuth authentication"` |
| `has:group` | Topics that belong to any group | `-has:group tag:feature` |

A group that was merged into another one resolves to the group it was merged into. An unknown group gives a warning and matches nothing.

### Commit Selectors

Hackorum imports commits from the git history and links them to threads. A commit is linked to a thread if its `Discussion:` trailer points at the thread, or if the thread lineage analysis found it.

`has:commit` is strict: it only counts those links. A thread that merely mentions a commit hash in a message does not match, check those by hand. A thread that no commit links to also does not mean nothing was committed, only that we did not find the link.

| Selector | Description | Example |
|----------|-------------|---------|
| `has:commit` | Topics linked to at least one commit | `has:commit` |
| `commit:sha` | Topics linked to this commit or one of its backports (7-40 hex characters, a prefix is enough) | `commit:3f2a9c1` |
| `commit:[...]` | Topics linked to a commit that matches all the conditions, see [commit: conditions](#commit-conditions) | `commit:[committer:tom, released:17]` |

```
has:commit                        # Threads that led to a commit
-has:commit has:patch             # Patches that never got committed (as far as we can tell)
commit:3f2a9c1                    # Thread behind this commit
```

### Fix Links

When a commit message names another commit by its hash (reverts, "follow-up to ...", "fixes ..."), we record a fix link between the threads of the two commits. That is all it means: a commit message names the other commit. It does not say the other commit was wrong, it covers reverts and plain follow-ups too, and both commits need a linked thread to get a link.

| Value | Description |
|-------|-------------|
| `has:later_fix` | Topics where a later commit names one of this topic's commits |
| `has:fixes` | Topics where a commit names an earlier commit of another topic |

```
has:later_fix                     # Committed work that needed a follow-up
has:fixes -has:later_fix          # Follow-up commits that nothing followed up on
has:later_fix commit:[released:18]   # A change released in 18, and a commit a later one names
```

### Patch CI and Apply State

These look at the current patchset of a thread, the same one the CI and "needs rebase" indicators in the topic list use. Threads without a patchset match none of the values, so a negation (`-ci:failing`) includes them.

`ci:` is the result of the CI run for the patchset:

| Value | Matches |
|-------|---------|
| `ci:passing` | CI passed |
| `ci:failing` | The build or the tests failed or timed out |
| `ci:pending` | Pushed and waiting for CI, queued, or running |
| `ci:none` | No CI result: CI was not run, the push failed, the run was cancelled or hit an infrastructure error |

`apply:` is how the patchset applies to current master:

| Value | Matches |
|-------|---------|
| `apply:applies` | Applies to master |
| `apply:needs_rebase` | Does not apply to master (or we could not judge its base), but is still worth retrying |
| `apply:awaiting_ci` | Not pushed yet, or CI is still in flight, so we do not touch it |
| `apply:wont_retry` | Given up on: no CI planned, a base too old, superseded by a commit, or the thread was merged into another |
| `apply:never_applied` | Never applied to any base |

```
ci:failing has:patch[from:me]     # My patches with failing CI
apply:needs_rebase from:me        # Threads I posted in that need a rebase
ci:pending -apply:wont_retry      # Waiting for CI, still active
```

## Dependent Conditions (Advanced)

Some selectors support **dependent conditions** using bracket notation. These sub-conditions apply specifically to the entity matched by the parent selector, rather than to the topic globally.

### Understanding the Difference

**Without dependent conditions:**
```
from:andres messages:>=10
```
This finds topics where Andres posted AND the topic has 10+ total messages (from anyone).

**With dependent conditions:**
```
from:andres[messages:>=10]
```
This finds topics where Andres *specifically* posted 10 or more messages.

### Syntax

Dependent conditions use brackets after the selector value, with comma-separated conditions inside:

```
selector:value[condition1:value1, condition2:value2]
```

### from: Conditions

Filter by the author's specific activity within a topic:

| Condition | Description | Example |
|-----------|-------------|---------|
| `messages:` | Author's message count | `from:andres[messages:>=10]` |
| `last_before:` | Author's last message before date | `from:heikki[last_before:1m]` |
| `last_after:` | Author's last message after date | `from:magnus[last_after:1w]` |
| `first_before:` | Author's first message before date | `from:michael[first_before:2024]` |
| `first_after:` | Author's first message after date | `from:amit[first_after:2024-01-01]` |
| `body:` | Author posted content matching | `from:alvaro[body:"patch"]` |

#### Examples

```
from:andres[messages:>=10]             # Andres posted 10+ messages
from:heikki[last_before:1m]            # Heikki hasn't posted in 1 month
from:thomas[body:"LGTM"]               # Thomas posted containing "LGTM"
from:core_team[messages:>=5]           # Team posted 5+ combined messages
from:magnus[messages:>=3, last_after:1w]  # Magnus: 3+ msgs and recent activity
```

#### Team Behavior

When using a team name with dependent conditions:

- **Message counts are aggregated**: `from:team[messages:>=10]` matches if team members combined posted 10+ messages
- **Date conditions apply per-member**: `from:team[last_before:1m]` matches topics where team members who posted have been inactive for 1 month

### has:attachment Conditions

Filter attachments by author or count:

| Condition | Description | Example |
|-----------|-------------|---------|
| `from:` | Attachments from author | `has:attachment[from:nathan]` |
| `count:` | Number of attachments | `has:attachment[count:>=3]` |
| `name:` | Attachment filename contains | `has:attachment[name:v2]` |

#### Examples

```
has:attachment[from:nathan]            # Attachments from Nathan
has:attachment[count:>=5]              # 5+ attachments total
has:attachment[from:peter,count:>=3]   # 3+ attachments from Peter
has:attachment[name:patch]             # Attachments with "patch" in name
```

### has:patch Conditions

Filter patch files by author or count:

| Condition | Description | Example |
|-----------|-------------|---------|
| `from:` | Patches from author | `has:patch[from:michael]` |
| `count:` | Number of attachments on patch messages | `has:patch[count:>=2]` |
| `after:` | A patch was posted after this person last wrote in the thread | `has:patch[after:me]` |
| `waiting:` | The newest patch is still waiting, see below | `has:patch[waiting:2w]` |

#### Examples

```
has:patch[from:michael]                # Patches from Michael
has:patch[count:>=3]                   # 3+ attachments on patch messages
has:patch[from:committer]              # Patches from any committer
```

#### Patch Progress

`after:` takes the same values as `from:` (`me`, names, teams, ...). `has:patch[after:me]` finds threads where I wrote, and somebody posted a patch after my last message there. If you are not signed in, `after:me` matches nothing and you get a warning.

`waiting:` finds threads where the newest patch has not gotten any attention:

- nobody but the patch author wrote in the thread since the patch
- no commit landed in the thread since the patch
- with a date (`waiting:2w`, `waiting:2024-01-01`), the patch also has to be older than that
- `waiting:any` or just `waiting:` means any age

With `from:` the newest patch from that person counts, not the newest patch overall.

```
has:patch[waiting:any]                 # Patches nobody reacted to
has:patch[waiting:1m]                  # ... for over a month
has:patch[after:me]                    # New patch since I posted
has:patch participants:1               # Only the author ever wrote in the thread
```

`has:patch participants:1` is the simple check for "only the author ever wrote", it does not care about commits or about which patch is the newest.

### commit: Conditions

Conditions inside one `commit:[...]` bracket all apply to the same change. A change is a commit together with its backports, so a condition can be met by the master commit and another by a back-branch commit of the same fix. Two separate `commit:` terms do not have this guarantee, each one can match a different commit of the thread.

| Condition | Description | Example |
|-----------|-------------|---------|
| `reviewer:` | Credited as reviewer | `commit:[reviewer:me]` |
| `reporter:` | Credited as reporter | `commit:[reporter:jian]` |
| `tester:` | Credited as tester | `commit:[tester:alexander]` |
| `author:` | Credited as author or co-author | `commit:[author:nathan]` |
| `committer:` | Committed by | `commit:[committer:tom]` |
| `released:` | Released in a version, see below | `commit:[released:17.2]` |
| `committed_after:` | Committed on or after date | `commit:[committed_after:2025-01-01]` |
| `committed_before:` | Committed before date | `commit:[committed_before:1y]` |

People values work like in `from:` (`me`, names, teams, contributor types).

Some things about credits:

- `reviewer:` also matches the committer of a patch written by somebody else, since committing it means reviewing the committed version.
- `author:` also matches co-authors, and authors that the lineage analysis found without a trailer naming them.
- Reviewers suggested only by the lineage analysis are not credited, and not searchable.
- Credits come from the commit message. A name that we could not match to a known person cannot be found by `reviewer:` and friends, even though it shows up in the commit.

`released:` takes a version number or `none`:

| Value | Matches |
|-------|---------|
| `released:17` | Any 17 release: 17.0, 17.2, 17beta1, 17rc1. Not 170.1 |
| `released:17.2` | 17.2 and its minor releases (17.2.1) |
| `released:8.4` | 8.4 and its minor releases (8.4.1, ...) |
| `released:none` | Changes none of whose commits was released yet |

Since a change includes its backports, `released:17` also finds a master commit whose backport shipped in 17.x.

```
commit:[reviewer:me, released:19]            # I reviewed it, it shipped in 19
commit:[committer:tom, committed_after:1y]   # Tom's commits in the last year
commit:[author:me, released:none]            # My commits that are not released
```

### tag: Conditions

Filter tags by author or when added:

| Condition | Description | Example |
|-----------|-------------|---------|
| `from:` | Tag added by source | `tag:review[from:me]` |
| `added_before:` | Tag added before date | `tag:important[added_before:1w]` |
| `added_after:` | Tag added after date | `tag:urgent[added_after:yesterday]` |

#### Examples

```
tag:review[from:me]                    # "review" tag from me
tag:[from:me]                          # Any tag from me
tag:important[added_after:1w]          # "important" tags added this week
tag:blocked[from:core_team]            # "blocked" by core team
tag:review[from:me, added_after:1m]    # My recent "review" tags
```

### Combining with Other Selectors

Dependent conditions work with all other search features:

```
from:andres[messages:>=10] has:patch   # Andres posted 10+ msgs AND has patches
has:attachment[from:amit] unread:me    # Amit's attachments I haven't read
from:committer[last_before:1m] -has:contributor  # Inactive committers
(from:alvaro[body:patch] OR has:patch[from:alvaro]) first_after:1m
```

### Selectors negation

You can negate selectors with dependent conditions:

```
-from:heikki[messages:>=10]            # Topics where Heikki did NOT post 10+ msgs
-has:attachment[from:bot]              # No attachments from bot
```

## Boolean Operators

### AND (Implicit and Explicit)

Terms separated by spaces are combined with AND:

```
vacuum autovacuum          # Both terms must match
```

You can also use explicit `AND`:

```
vacuum AND autovacuum      # Same as above
```

### OR

Use `OR` to match either term:

```
vacuum OR autovacuum       # Either term matches
from:robert OR from:thomas # Messages from either author
```

### Operator Precedence

AND binds more tightly than OR. This query:

```
from:robert unread:me OR from:thomas
```

Is interpreted as:

```
(from:robert AND unread:me) OR from:thomas
```

## Grouping with Parentheses

Use parentheses to control grouping:

```
(from:robert OR from:thomas) unread:me
```

This finds unread topics from either Robert or Thomas.

More complex example:

```
(has:patch OR has:attachment) first_after:1m -has:contributor
```

This finds recent topics with patches or attachments that haven't received contributor attention.

## Negation

Prefix any term or selector with `-` to exclude matches:

```
-from:bot                  # Exclude bot messages
vacuum -autovacuum         # Vacuum but not autovacuum
-has:contributor           # No contributor activity
```

Negate grouped expressions:

```
-(from:tom OR from:bruce)  # Exclude both authors
```

## Full-Text Search

Text searches use PostgreSQL's full-text search with English stemming:

- `running` matches "run", "runs", "running"
- `databases` matches "database", "databases"
- Common words (stop words) like "the", "a", "is" are ignored

For exact phrase matching, use quotes:

```
"shared buffers"           # Exact phrase
title:"query planning"     # Exact phrase in title
```

## Example Queries

### Finding Unanswered Patch Submissions

```
has:patch messages:1 first_after:1m
```

Single-message topics with patches submitted in the last month.

### Your Team's Reading Queue

```
unread:my-team has:contributor first_after:2w
```

Recent topics with contributor activity that no team member has read.

### Researching a Topic

```
"logical replication" from:committer first_after:2023
```

Discussions about logical replication from committers since 2023.

### Finding Your Contributions

```
from:me first_after:1y
```

Topics where you've participated in the last year.

### Active Discussions Without Resolution

```
messages:>20 last_after:1w -has:committer
```

Long discussions with recent activity but no committer involvement.

### Patch Reviews Needed

```
has:patch -has:contributor first_after:2w participants:<3
```

Recent patches that haven't received contributor attention and have few participants.

### Active Contributors Who've Gone Quiet

```
from:committer[last_before:1m, messages:>=5]
```

Topics where a committer was actively participating (5+ messages) but hasn't posted in over a month.

### Patches from Specific Author

```
has:patch[from:nathan,count:>=2] first_after:1m
```

Recent topics with multiple patches submitted by Nathan.

### Bug Reports Without a Commit

```
tag:bug -tag:not-a-bug -has:commit
```

Threads classified as bug reports that no commit is linked to. This is a saved search too.

### Patches Waiting for Review

```
has:patch[waiting:any]
```

The newest patch has no reply from anyone else and no commit landed since. Add a date, `has:patch[waiting:1m]`, to only see the ones that have been waiting for a month.

### New Patch Since I Posted

```
has:patch[after:me]
```

Somebody posted a patch in a thread after my last message.

### Reviews That Made It

```
commit:[reviewer:me, released:19]
```

Threads where a commit credits me as reviewer and the change is in a version 19 release.

### Broken Patches of Mine

```
ci:failing has:patch[from:me]
apply:needs_rebase from:me
```

Threads where my patch fails CI, and threads I posted in that need a rebase.

### Committed Work That Needed a Fix

```
has:later_fix commit:[released:18]
```

Threads with a change released in 18 and a commit that a later commit message names.

### Finding Your Tagged Reviews

```
tag:needs-review[from:me, added_after:1w] -read:me
```

Topics you tagged "needs-review" in the last week that you haven't fully read.

## Selector Reference

| Category | Selectors |
|----------|-----------|
| **Content** | `title:`, `body:` |
| **Author** | `from:`*, `starter:`, `last_from:` |
| **Dates** | `first_after:`, `first_before:`, `messages_after:`, `messages_before:`, `last_after:`, `last_before:` |
| **Counts** | `messages:`, `participants:`, `contributors:` |
| **Presence** | `has:attachment`*, `has:patch`*, `has:contributor`, `has:committer`, `has:core_team`, `has:commitfest`, `has:commit`, `has:later_fix`, `has:fixes`, `has:group` |
| **Commits** | `commit:sha`, `commit:[...]`* |
| **Patch state** | `ci:` (`passing`, `failing`, `pending`, `none`), `apply:` (`applies`, `needs_rebase`, `awaiting_ci`, `wont_retry`, `never_applied`) |
| **Groups** | `group:` |
| **State** | `unread:`, `read:`, `reading:`, `new:`, `starred:`, `notes:`, `ignored:` |
| **Lists** | `list:` (mailing list display name, e.g. `list:hackers`), `hidden:true`/`hidden:false` |
| **Tags** | `tag:tagname`*, `tag:[from:source]` |

*Supports [dependent conditions](#dependent-conditions-advanced)

### Dependent Condition Reference

| Parent Selector | Available Conditions |
|-----------------|---------------------|
| `from:` | `messages:`, `last_before:`, `last_after:`, `first_before:`, `first_after:`, `body:` |
| `has:attachment` | `from:`, `count:`, `name:` |
| `has:patch` | `from:`, `count:`, `after:`, `waiting:` |
| `commit:` | `reviewer:`, `reporter:`, `tester:`, `author:`, `committer:`, `released:`, `committed_after:`, `committed_before:` |
| `tag:` | `from:`, `added_before:`, `added_after:` |
