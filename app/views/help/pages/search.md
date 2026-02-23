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
| `commitfest:[name:name]` | Topics from commitfest with this name | `commitfest:[name:PG19-Draft]` |
| `commitfest:[status:status]` | Topics from commitfest with this status | `commitfest:[status:commited]` |
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
| `has:patch` | Topics with `.patch` or `.diff` files |
| `has:contributor` | Topics with PostgreSQL contributor activity |
| `has:committer` | Topics with committer activity |
| `has:core_team` | Topics with core team activity |

```
has:patch first_after:1m         # Recent topics with patches
has:contributor messages:>5      # Active discussions with contributor input
```

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

#### Team State Selectors

Replace `me` with a team name to filter by team state (you must be a team member):

```
unread:core-reviewers      # Topics unread by anyone on the team
starred:review-team        # Topics starred by any team member
```

### Tag Selectors

Search for topics by tags added to notes. Tags are private to the note author and mentioned users/teams.

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
| `count:` | Number of patches | `has:patch[count:>=2]` |

#### Examples

```
has:patch[from:michael]                # Patches from Michael
has:patch[count:>=3]                   # 3+ patch files
has:patch[from:committer]              # Patches from any committer
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

### Negation

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
| **Presence** | `has:attachment`*, `has:patch`*, `has:contributor`, `has:committer`, `has:core_team` |
| **State** | `unread:`, `read:`, `reading:`, `new:`, `starred:`, `notes:` |
| **Tags** | `tag:tagname`*, `tag:[from:source]` |

*Supports [dependent conditions](#dependent-conditions-advanced)

### Dependent Condition Reference

| Parent Selector | Available Conditions |
|-----------------|---------------------|
| `from:` | `messages:`, `last_before:`, `last_after:`, `first_before:`, `first_after:`, `body:` |
| `has:attachment` | `from:`, `count:`, `name:` |
| `has:patch` | `from:`, `count:` |
| `tag:` | `from:`, `added_before:`, `added_after:` |
